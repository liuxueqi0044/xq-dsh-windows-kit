[CmdletBinding()]
param([string]$Root, [switch]$RequireComplete, [switch]$AsLibrary)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Id,[string]$Status,[string]$Message) { [void]$results.Add([pscustomobject]@{ Id=$Id; Status=$Status; Message=$Message }) }
function Pending([string]$Id,[string]$Message) { Add-Result $Id 'PENDING' $Message }
function Check([string]$Id,[bool]$Ok,[string]$Pass,[string]$Fail) { Add-Result $Id ($(if($Ok){'PASS'}else{'FAIL'})) ($(if($Ok){$Pass}else{$Fail})) }
$launcher = Join-Path $Root 'launcher/Start-XQDSH.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
  foreach($id in @('RUN-002','RUN-004','RUN-005','RUN-012','RUN-013')) { Pending $id 'launcher/Start-XQDSH.ps1 is not present yet' }
} else {
  $source = Get-Content -LiteralPath $launcher -Raw
  $unsafe = '(?i)(Invoke-Expression|cmd\s*/c|schtasks|New-Service|sc\.exe\s+create|Register-ScheduledTask|New-NetFirewallRule|CurrentUser\\Run|RunOnce)'
  Check 'RUN-013' (-not ($source -match $unsafe)) 'No unsafe shell, service, task, firewall, or persistence keyword found' 'Unsafe shell or persistence keyword found'

  # GitHub-hosted Windows runners use Windows Server, while the product correctly
  # rejects anything except Windows 11 x64. Keep that production guard intact and
  # shadow only Get-CimInstance inside a disposable child-process wrapper so the
  # dry-run and cancellation branches remain testable on hosted CI.
  $platformWrapper = $null
  $launcherUnderTest = $launcher
  try {
    $hostOs = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $hostComputer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $hostIsUnsupported = ($hostOs.Caption -notmatch 'Windows 11' -or [version]$hostOs.Version -lt [version]'10.0.22000.0' -or $hostComputer.SystemType -notmatch 'x64|64-bit')
  } catch { $hostIsUnsupported = $true }
  $requiresPlatformFixture = ($hostIsUnsupported -or $env:XQ_M05_FORCE_PLATFORM_FIXTURE -eq '1')
  if ($requiresPlatformFixture) {
    if ($hostIsUnsupported) {
      $guardPath = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-platform-guard-' + [guid]::NewGuid().ToString('N'))
      $guardOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -WorkspacePath $guardPath -ManifestPath (Join-Path $Root 'manifest\product-manifest.json') -WhatIf -Confirm:$false 2>&1)
      $guardCode = $LASTEXITCODE
      Check 'RUN-CI-PLATFORM-GUARD' (($guardCode -ne 0) -and (($guardOutput -join "`n") -match 'PLATFORM_(UNSUPPORTED|UNKNOWN)') -and (-not (Test-Path -LiteralPath $guardPath))) 'Unsupported CI host was rejected before the platform fixture was used' 'Production platform guard did not fail closed on the unsupported CI host'
    }

    $platformWrapper = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-platform-fixture-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $wrapperSource = @'
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$LauncherPath,
  [Parameter(Mandatory=$true)][string]$WorkspacePath,
  [Parameter(Mandatory=$true)][string]$ManifestPath,
  [switch]$WhatIf,
  [string]$Confirm = 'true'
)
function Get-CimInstance {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$ClassName,[string]$Filter)
  if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ Caption='Microsoft Windows 11 Pro'; Version='10.0.26100.0' } }
  if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ SystemType='x64-based PC' } }
  throw ('Unexpected CIM query in CI platform fixture: ' + $ClassName)
}
& $LauncherPath -WorkspacePath $WorkspacePath -ManifestPath $ManifestPath -WhatIf:$WhatIf -Confirm $Confirm
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($platformWrapper,$wrapperSource,(New-Object Text.UTF8Encoding($false)))
    $launcherUnderTest = $platformWrapper
  }

  function Get-XQLauncherArguments([string]$Workspace,[string]$ManifestPath,[switch]$DryRun) {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcherUnderTest)
    if ($null -ne $platformWrapper) { $arguments += @('-LauncherPath',$launcher) }
    $arguments += @('-WorkspacePath',$Workspace,'-ManifestPath',$ManifestPath)
    if ($DryRun) { $arguments += @('-WhatIf','-Confirm:false') }
    return @($arguments)
  }

  function Get-XQDSHProcessIds {
    # GitHub runners can start unrelated npx processes between snapshots. Limit
    # the assertion to a process whose command line identifies this DSH launch.
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -match '^(?i)(node|npm|npx|dsh)(\.exe)?$' -and
        $_.CommandLine -match '(?i)(@deepseek-ai[\\/]dsh|XQ-DSH-Safe\.patch\.yml)'
      } |
      Select-Object -ExpandProperty ProcessId)
  }

  $whatIfPath = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-whatif-' + [guid]::NewGuid().ToString('N'))
  $manifest = Join-Path $Root 'manifest\product-manifest.json'
  $before = @(Get-XQDSHProcessIds)
  try {
    $whatIfArguments = @(Get-XQLauncherArguments -Workspace $whatIfPath -ManifestPath $manifest -DryRun)
    $out = @(& powershell.exe @whatIfArguments 2>&1)
    $code = $LASTEXITCODE
    $after = @(Get-XQDSHProcessIds)
    $new = @($after | Where-Object { $before -notcontains $_ })
    $planText = $out -join "`n"
    $planMatched = $planText -match '(?i)(what.?if|plan|would)'
    if (($code -eq 0) -and ($new.Count -eq 0) -and $planMatched) {
      Add-Result 'RUN-004' 'PASS' 'WhatIf succeeded with a plan and no DSH/npx process'
    } else {
      $signals = @([regex]::Matches($planText,'\[(?<code>[A-Z0-9_-]+)\]') | ForEach-Object { $_.Groups['code'].Value } | Select-Object -Unique) -join ','
      if ([string]::IsNullOrWhiteSpace($signals)) { $signals = 'none' }
      Add-Result 'RUN-004' 'FAIL' ('WhatIf contract failed: exitCode={0}; planMatched={1}; newDshProcesses={2}; signals={3}' -f $code,$planMatched,$new.Count,$signals)
    }
  } catch { Add-Result 'RUN-004' 'FAIL' ('WhatIf invocation failed: ' + $_.Exception.Message) }
  # An altered copy is supplied only as a temporary test input; it is never downloaded or executed.
  $tampered = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-tampered-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $m = Get-Content (Join-Path $Root 'manifest\product-manifest.json') -Raw | ConvertFrom-Json
    $m.upstream.packageName = 'evil/dsh'; [IO.File]::WriteAllText($tampered, ($m | ConvertTo-Json -Depth 20))
    $tamperedArguments = @(Get-XQLauncherArguments -Workspace $whatIfPath -ManifestPath $tampered -DryRun)
    $out2 = @(& powershell.exe @tamperedArguments 2>&1)
    Check 'RUN-002' (($LASTEXITCODE -ne 0) -and (($out2 -join "`n") -match '(?i)(manifest|package|reject|invalid|block)')) 'Tampered manifest was rejected' 'Tampered manifest was not clearly rejected'
  } catch { Add-Result 'RUN-002' 'FAIL' ('Tampered manifest test failed: ' + $_.Exception.Message) }
  finally { if (Test-Path -LiteralPath $tampered) { Remove-Item -LiteralPath $tampered -Force -ErrorAction SilentlyContinue } }
  function Invoke-SafeChild([string]$Workspace,[string]$InputText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $childArguments = @(Get-XQLauncherArguments -Workspace $Workspace -ManifestPath $manifest)
    if (@($childArguments | Where-Object { $_ -match '"' }).Count -gt 0) { throw 'A controlled test path unexpectedly contains a quote.' }
    $psi.Arguments = @($childArguments | ForEach-Object { '"' + [string]$_ + '"' }) -join ' '
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi; [void]$p.Start(); $p.StandardInput.WriteLine($InputText); $p.StandardInput.Close()
    $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit(); [pscustomobject]@{ Code=$p.ExitCode; Output=($stdout + $stderr) }
  }
  $wide = Invoke-SafeChild 'C:\' ''
  Check 'RUN-005-wide' ($wide.Code -ne 0) 'Root workspace was rejected' 'Root workspace was not rejected'
  $nonEmpty = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-nonempty-' + [guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($nonEmpty) | Out-Null
  $marker = Join-Path $nonEmpty 'marker.txt'; [IO.File]::WriteAllText($marker,'FAKE_TEST_MARKER')
  try { $beforeText = [IO.File]::ReadAllText($marker); $ne = Invoke-SafeChild $nonEmpty ''; $afterText = [IO.File]::ReadAllText($marker); Check 'RUN-005-nonempty' (($ne.Code -ne 0) -and ($beforeText -eq $afterText)) 'Non-empty workspace was rejected without content change' 'Non-empty workspace was not safely rejected' } finally { Remove-Item -LiteralPath $nonEmpty -Recurse -Force -ErrorAction SilentlyContinue }
  $cancelPath = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-cancel-' + [guid]::NewGuid().ToString('N')); $cancel = Invoke-SafeChild $cancelPath 'NO'
  Check 'RUN-012' (($cancel.Code -ne 0) -and ($cancel.Output -match 'USER_CANCELLED') -and (-not (Test-Path $cancelPath))) 'Cancellation returned USER_CANCELLED with no workspace creation' 'Cancellation contract failed'
  if ($null -ne $platformWrapper -and (Test-Path -LiteralPath $platformWrapper -PathType Leaf)) { Remove-Item -LiteralPath $platformWrapper -Force -ErrorAction SilentlyContinue }
}
$results
$blocking = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0
if ($RequireComplete -and (@($results | Where-Object { $_.Status -eq 'PENDING' }).Count -gt 0)) { $blocking = $true }
if ((-not $AsLibrary) -and $blocking) { exit 1 }

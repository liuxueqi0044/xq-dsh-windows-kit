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
  $whatIfPath = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-whatif-' + [guid]::NewGuid().ToString('N'))
  $manifest = Join-Path $Root 'manifest\product-manifest.json'
  $before = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(npx|dsh)$' } | Select-Object -ExpandProperty Id)
  try {
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -WorkspacePath $whatIfPath -ManifestPath $manifest -WhatIf -Confirm:$false 2>&1)
    $code = $LASTEXITCODE
    $after = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(npx|dsh)$' } | Select-Object -ExpandProperty Id)
    $new = @($after | Where-Object { $before -notcontains $_ })
    Check 'RUN-004' (($code -eq 0) -and ($new.Count -eq 0) -and (($out -join "`n") -match '(?i)(what.?if|plan|would)')) 'WhatIf succeeded with a plan and no DSH/npx process' 'WhatIf did not produce a safe plan or spawned a process'
  } catch { Add-Result 'RUN-004' 'FAIL' ('WhatIf invocation failed: ' + $_.Exception.Message) }
  # An altered copy is supplied only as a temporary test input; it is never downloaded or executed.
  $tampered = Join-Path ([IO.Path]::GetTempPath()) ('xq-m05-tampered-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $m = Get-Content (Join-Path $Root 'manifest\product-manifest.json') -Raw | ConvertFrom-Json
    $m.upstream.packageName = 'evil/dsh'; [IO.File]::WriteAllText($tampered, ($m | ConvertTo-Json -Depth 20))
    $out2 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -WorkspacePath $whatIfPath -ManifestPath $tampered -WhatIf -Confirm:$false 2>&1)
    Check 'RUN-002' (($LASTEXITCODE -ne 0) -and (($out2 -join "`n") -match '(?i)(manifest|package|reject|invalid|block)')) 'Tampered manifest was rejected' 'Tampered manifest was not clearly rejected'
  } catch { Add-Result 'RUN-002' 'FAIL' ('Tampered manifest test failed: ' + $_.Exception.Message) }
  finally { if (Test-Path -LiteralPath $tampered) { Remove-Item -LiteralPath $tampered -Force -ErrorAction SilentlyContinue } }
  function Invoke-SafeChild([string]$Workspace,[string]$InputText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -WorkspacePath "{1}" -ManifestPath "{2}"' -f $launcher,$Workspace,$manifest
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
}
$results
$blocking = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0
if ($RequireComplete -and (@($results | Where-Object { $_.Status -eq 'PENDING' }).Count -gt 0)) { $blocking = $true }
if ((-not $AsLibrary) -and $blocking) { exit 1 }

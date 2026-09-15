[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [ValidateSet('Human','Json')][string]$OutputFormat = 'Human',
    [string]$ManifestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $PSScriptRoot '..\_internal\manifest\product-manifest.json' }
Import-Module (Join-Path $PSScriptRoot '..\_internal\lib\XQDSH.Common.psm1') -Force

function Add-XQResult { param($Result) $script:Results += $Result }
function Get-XQVersionResult {
    param([string]$Name)
    $info = Get-XQCommandInfo -Name $Name -Arguments @('--version') -TimeoutSeconds 8
    if (-not $info.Passed) { return New-XQCheckResult $false 'BLOCKER' ($Name.ToUpperInvariant() + '_MISSING') ($Name + ' is required but unavailable.') $info.Evidence }
    $match = [regex]::Match([string]$info.Evidence.Output, '[vV]?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?')
    if (-not $match.Success) { return New-XQCheckResult $false 'BLOCKER' ($Name.ToUpperInvariant() + '_VERSION_UNKNOWN') ($Name + ' returned no recognizable version.') $info.Evidence }
    New-XQCheckResult $true 'INFO' ($Name.ToUpperInvariant() + '_FOUND') ($Name + ' is available.') ([pscustomobject]@{ Path=$info.Evidence.Path; Version=$match.Value })
}

$Results = @()
try {
    $manifestRead = Read-XQProductManifest -ManifestPath $ManifestPath
    Add-XQResult $manifestRead
    if (-not $manifestRead.Passed) { throw [System.InvalidOperationException]::new('Manifest is invalid.') }
    $policy = Test-XQManifestRuntimePolicy -Manifest $manifestRead
    Add-XQResult $policy
    if (-not $policy.Passed) { throw [System.InvalidOperationException]::new('Manifest policy is invalid.') }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $isWin11 = ($os.Caption -match 'Windows 11') -and ([version]$os.Version -ge [version]'10.0.22000.0')
    $isX64 = $computer.SystemType -match 'x64|64-bit'
    Add-XQResult (New-XQCheckResult ($isWin11 -and $isX64) ($(if($isWin11 -and $isX64){'INFO'}else{'BLOCKER'})) ($(if($isWin11 -and $isX64){'OS_SUPPORTED'}else{'OS_UNSUPPORTED'})) ($(if($isWin11 -and $isX64){'Windows 11 x64 is detected.'}else{'Windows 11 x64 is required.'})) ([pscustomobject]@{ Caption=$os.Caption; Version=$os.Version; Build=$os.BuildNumber; SystemType=$computer.SystemType }))
    $admin = $false; try { $identity=[Security.Principal.WindowsIdentity]::GetCurrent(); $admin=(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
    Add-XQResult (New-XQCheckResult $true 'INFO' 'ADMIN_STATUS' 'Administrator status is informational only; no elevation is requested.' ([pscustomobject]@{ IsAdministrator=$admin }))

    $node = Get-XQVersionResult 'node'; Add-XQResult $node
    if ($node.Passed) { Add-XQResult (Test-XQSupportedNodeVersion -VersionText $node.Evidence.Version -SupportedRange ([string]$manifestRead.Evidence.Manifest.runtime.nodeRange)) }
    Add-XQResult (Get-XQVersionResult 'npm')
    $npx = Get-XQVersionResult 'npx'; if ($npx.Passed) { Add-XQResult $npx } else { Add-XQResult (New-XQCheckResult $false 'BLOCKER' 'NPX_MISSING' 'npx is required but unavailable.' $npx.Evidence) }
    $pnpm = Get-XQVersionResult 'pnpm'; if ($pnpm.Passed) { Add-XQResult $pnpm } else { Add-XQResult (New-XQCheckResult $true 'WARNING' 'PNPM_MISSING' 'pnpm is optional and unavailable.' $pnpm.Evidence) }

    Add-XQResult (Get-XQPortState -Port 3080)
    $dsh = Get-XQCommandInfo -Name 'dsh' -Arguments @('--version') -TimeoutSeconds 8
    if ($dsh.Passed) { Add-XQResult (New-XQCheckResult $true 'INFO' 'DSH_FOUND' 'dsh command is available.' $dsh.Evidence) } else { Add-XQResult (New-XQCheckResult $true 'WARNING' 'DSH_NOT_FOUND' 'dsh command is not currently found; it is not installed by this checker.' $dsh.Evidence) }
    # Do not invoke npm cache commands: newer npm versions reject "cache dir" and write a log
    # for that rejected command.  The standard Windows cache path can be inspected as metadata.
    $cachePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'npm-cache'
    $lockVersion=[string]$policy.Evidence.Version; $hint=$false
    try { if (Test-Path -LiteralPath $cachePath) { $hint = @([System.IO.Directory]::EnumerateFileSystemEntries($cachePath, '*', [System.IO.SearchOption]::TopDirectoryOnly) | Where-Object { $_ -match [regex]::Escape($lockVersion) }).Count -gt 0 } } catch {}
    Add-XQResult (New-XQCheckResult $true 'INFO' 'NPM_CACHE_CHECKED' 'Standard npm cache metadata was checked without running npm or accessing the network.' ([pscustomobject]@{ CachePath=$cachePath; Exists=(Test-Path -LiteralPath $cachePath); LockedPackageHint=$hint }))
    $dshHome = Get-XQDshHomePath; if ($dshHome.Passed) { Add-XQResult (New-XQCheckResult $true 'INFO' 'DSH_HOME_STATUS' 'DSH Home metadata was checked without reading its contents.' ([pscustomobject]@{ Path=$dshHome.Evidence.Path; Exists=[bool]$dshHome.Evidence.Exists })) } else { Add-XQResult $dshHome }
    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) { $WorkspacePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'XQ-DSH-Sandbox' }
    Add-XQResult (Test-XQSafeWorkspace -Path $WorkspacePath -FirstRun)
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($WorkspacePath)); $drive=Get-PSDrive -Name $root.Substring(0,1) -ErrorAction SilentlyContinue
    if ($null -eq $drive) { Add-XQResult (New-XQCheckResult $false 'UNKNOWN' 'WORKSPACE_VOLUME_UNKNOWN' 'Workspace volume free space could not be determined.' $null) } else { $free=[int64]$drive.Free; $minimum=2GB; Add-XQResult (New-XQCheckResult ($free -ge $minimum) ($(if($free -ge $minimum){'INFO'}else{'BLOCKER'})) ($(if($free -ge $minimum){'WORKSPACE_SPACE_OK'}else{'WORKSPACE_SPACE_LOW'})) 'Workspace volume free space was checked.' ([pscustomobject]@{ FreeBytes=$free; MinimumBytes=$minimum; Root=$root })) }
} catch {
    Add-XQResult (New-XQCheckResult $false 'ERROR' 'ENV_CHECK_INTERNAL_ERROR' 'Environment check could not continue safely.' $null)
}
$payload = [pscustomobject][ordered]@{ Tool='Test-XQDSHEnvironment'; Results=@($Results); Passed=(@($Results | Where-Object { -not $_.Passed -and $_.Severity -in @('BLOCKER','ERROR','UNKNOWN') }).Count -eq 0) }
if ($OutputFormat -eq 'Json') { $payload | ConvertTo-Json -Depth 8 -Compress } else { $Results | ForEach-Object { '{0,-8} {1,-32} {2}' -f $_.Severity,$_.Code,$_.Message } }
if ($payload.Passed) { exit 0 }
if (@($Results | Where-Object { $_.Code -like 'MANIFEST_*' }).Count -gt 0) { exit 3 }
exit 2

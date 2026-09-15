[CmdletBinding()]
param(
    [string]$WorkspacePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateSet('web')][string]$Profile = 'web',
    [string]$ManifestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $PSScriptRoot '..\manifest\product-manifest.json' }
Import-Module (Join-Path $PSScriptRoot '..\lib\XQDSH.Common.psm1') -Force

$script:RedactionVersion = '1'
$script:SchemaVersion = '1'
$script:MaxPackageJsonBytes = 524288

function Get-XQSafeText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    return (Protect-XQSensitiveText -Text ([string]$Value)).Evidence.Text
}

function New-XQStatus {
    param([Parameter(Mandatory=$true)][string]$Status, [string]$Code)
    return [pscustomobject][ordered]@{ status = $Status; code = $Code }
}

function Get-XQVersionProbe {
    param([Parameter(Mandatory=$true)][string]$Name)
    $probe = Get-XQCommandInfo -Name $Name -Arguments @('--version') -TimeoutSeconds 8
    if (-not $probe.Passed) { return [pscustomobject][ordered]@{ name=$Name; status='UNAVAILABLE'; version=$null; errorCode=$probe.Code } }
    $match = [regex]::Match([string]$probe.Evidence.Output, '[vV]?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?')
    if (-not $match.Success) { return [pscustomobject][ordered]@{ name=$Name; status='UNKNOWN'; version=$null; errorCode='VERSION_UNPARSEABLE' } }
    return [pscustomobject][ordered]@{ name=$Name; status='AVAILABLE'; version=(Get-XQSafeText $match.Value); errorCode=$null }
}

function Get-XQOperatingSystemMetadata {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        return [pscustomobject][ordered]@{ status='AVAILABLE'; caption=(Get-XQSafeText $os.Caption); version=(Get-XQSafeText $os.Version); architecture=(Get-XQSafeText $computer.SystemType); errorCode=$null }
    } catch { return [pscustomobject][ordered]@{ status='UNAVAILABLE'; caption=$null; version=$null; architecture=$null; errorCode='OS_METADATA_UNAVAILABLE' } }
}

function Get-XQListenerMetadata {
    param([int]$Port)
    try {
        $addresses = @(); $pids = @()
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            $items = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
            $addresses = @($items | ForEach-Object { Get-XQSafeText $_.LocalAddress } | Select-Object -Unique)
            $pids = @($items | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { [int]$_ })
        } else {
            $items = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port })
            $addresses = @($items | ForEach-Object { Get-XQSafeText $_.Address.ToString() } | Select-Object -Unique)
        }
        return [pscustomobject][ordered]@{ status='AVAILABLE'; host='127.0.0.1'; port=$Port; listening=($addresses.Count -gt 0); addresses=$addresses; processIds=$pids; errorCode=$null }
    } catch { return [pscustomobject][ordered]@{ status='UNAVAILABLE'; host='127.0.0.1'; port=$Port; listening=$false; addresses=@(); processIds=@(); errorCode='LISTENER_METADATA_UNAVAILABLE' } }
}

function Get-XQPluginMetadata {
    param([string]$ProfileRoot)
    $path = Join-Path $ProfileRoot 'package.json'
    if (-not [System.IO.File]::Exists($path)) { return [pscustomobject][ordered]@{ status='NOT_FOUND'; items=@(); errorCode='PROFILE_PACKAGE_JSON_NOT_FOUND' } }
    try {
        $file = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($file.Length -gt $script:MaxPackageJsonBytes) { return [pscustomobject][ordered]@{ status='REFUSED'; items=@(); errorCode='PROFILE_PACKAGE_JSON_TOO_LARGE' } }
        $package = [System.IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        # Read only dependency maps. No plugin configuration values are retained.
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($mapName in @('dependencies','optionalDependencies')) {
            $map = $package.PSObject.Properties[$mapName]
            if ($null -ne $map -and $null -ne $map.Value) {
                foreach ($property in @($map.Value.PSObject.Properties | Sort-Object Name)) {
                    [void]$items.Add([pscustomobject][ordered]@{ name=(Get-XQSafeText $property.Name); version=(Get-XQSafeText ([string]$property.Value)) })
                }
            }
        }
        return [pscustomobject][ordered]@{ status='AVAILABLE'; items=@($items); errorCode=$null }
    } catch { return [pscustomobject][ordered]@{ status='UNAVAILABLE'; items=@(); errorCode='PROFILE_PACKAGE_JSON_UNREADABLE' } }
}

function Get-XQSkillMetadata {
    param([string]$ProfileRoot)
    $skillsRoot = Join-Path $ProfileRoot 'skills'
    if (-not [System.IO.Directory]::Exists($skillsRoot)) { return [pscustomobject][ordered]@{ status='NOT_FOUND'; items=@(); errorCode='SKILLS_DIRECTORY_NOT_FOUND' } }
    try {
        # Intentionally enumerate directory names only. SKILL.md is never opened.
        $items = @([System.IO.Directory]::EnumerateDirectories($skillsRoot, '*', [System.IO.SearchOption]::TopDirectoryOnly) | ForEach-Object {
            [pscustomobject][ordered]@{ name=(Get-XQSafeText ([System.IO.Path]::GetFileName($_))); source='profile' }
        } | Sort-Object name)
        return [pscustomobject][ordered]@{ status='AVAILABLE'; items=$items; errorCode=$null }
    } catch { return [pscustomobject][ordered]@{ status='UNAVAILABLE'; items=@(); errorCode='SKILLS_DIRECTORY_UNREADABLE' } }
}

function Get-XQWorkspaceRisk {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return [pscustomobject][ordered]@{ provided=$false; risk='NOT_PROVIDED'; errorCode=$null } }
    $result = Test-XQSafeWorkspace -Path $Path
    if ($result.Passed) { return [pscustomobject][ordered]@{ provided=$true; risk='NARROW_CANDIDATE'; errorCode=$null } }
    return [pscustomobject][ordered]@{ provided=$true; risk='REJECTED'; errorCode=$result.Code }
}

function Test-XQDiagnosticObject {
    param($Report)
    $required = @('$schema','tool','toolVersion','schemaVersion','redactionVersion','generatedAtUtc','operatingSystem','commands','listener','dsh','workspace','launcherSummary')
    $actual = @($Report.PSObject.Properties | ForEach-Object { $_.Name })
    if (@($required | Where-Object { $actual -notcontains $_ }).Count -ne 0 -or @($actual | Where-Object { $required -notcontains $_ }).Count -ne 0) { return $false }
    return ($Report.'$schema' -eq '../schemas/diagnostic-report.schema.json' -and $Report.tool -eq 'New-XQDSHDiagnosticReport' -and $Report.schemaVersion -eq $script:SchemaVersion -and $Report.redactionVersion -eq $script:RedactionVersion)
}

function Test-XQSerializedDiagnosticSafety {
    param([Parameter(Mandatory=$true)][string]$Text)
    # Recognize raw secret forms while permitting the explicit markers produced by
    # the field pass. Re-applying the generic redactor here would redact the word
    # following "Bearer" inside its own marker and make every safe report fail.
    $unsafe = @(
        '(?i)Authorization\s*:\s*Bearer\s+(?!\[REDACTED:BEARER\])[^\s,;]+',
        '\bsk-[A-Za-z0-9_-]{8,}\b',
        '\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b',
        '(?i)[?&](?:token|key|secret|password|cookie)=(?!\[REDACTED:(?:URL_SECRET|SECRET)\])[^&#\s]+',
        '(?i)https?://(?!\[REDACTED:URL_USERINFO\]@)[^/@\s:]+:[^/@\s]+@',
        '(?im)\b(?:password|token|api[_-]?key|secret|cookie)\b\s*[:=]\s*(?!\[REDACTED:SECRET\])(?:"[^"\r\n]*"|''[^''\r\n]*''|[^\s,;]+)'
    )
    foreach ($pattern in $unsafe) { if ([regex]::IsMatch($Text, $pattern)) { return $false } }
    return $true
}

function Write-XQNewDiagnosticReport {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Text)
    $full = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($directory) -or -not [System.IO.Directory]::Exists($directory)) { throw [System.IO.DirectoryNotFoundException]::new('Output directory does not exist.') }
    if ([System.IO.File]::Exists($full)) { throw [System.IO.IOException]::new('Output file already exists; diagnostic reports are never overwritten.') }
    $temp = Join-Path $directory ('.xq-diagnostics-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $stream = New-Object System.IO.FileStream($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $bytes = $utf8.GetBytes($Text); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # File.Move is an atomic same-volume rename and refuses an existing destination.
        [System.IO.File]::Move($temp, $full)
    } finally { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } }
}

try {
    # The product contract freezes this diagnostic to the loopback Web port.
    # Do not let a malformed external manifest alter the report schema.
    $port = 3080
    $homeResult = Get-XQDshHomePath
    $homeExists = $false; $profileRoot = $null
    if ($homeResult.Passed) { $homeExists = [bool]$homeResult.Evidence.Exists; $profileRoot = Join-Path $homeResult.Evidence.Path ('profiles\' + $Profile) }
    $profileExists = ($null -ne $profileRoot -and [System.IO.Directory]::Exists($profileRoot))
    $report = [pscustomobject][ordered]@{
        '$schema' = '../schemas/diagnostic-report.schema.json'; tool='New-XQDSHDiagnosticReport'; toolVersion='1.0.0'; schemaVersion=$script:SchemaVersion; redactionVersion=$script:RedactionVersion; generatedAtUtc=[DateTime]::UtcNow.ToString('o')
        operatingSystem=Get-XQOperatingSystemMetadata; commands=@('node','npm','npx','pnpm','dsh' | ForEach-Object { Get-XQVersionProbe $_ }); listener=Get-XQListenerMetadata -Port $port
        dsh=[pscustomobject][ordered]@{ homeExists=$homeExists; profile=[pscustomobject][ordered]@{ name='web'; exists=$profileExists }; plugins=$(if($profileExists){Get-XQPluginMetadata $profileRoot}else{[pscustomobject][ordered]@{ status='NOT_RUN'; items=@(); errorCode='PROFILE_NOT_FOUND' }}); skills=$(if($profileExists){Get-XQSkillMetadata $profileRoot}else{[pscustomobject][ordered]@{ status='NOT_RUN'; items=@(); errorCode='PROFILE_NOT_FOUND' }}); dumpConfig=[pscustomobject][ordered]@{ status='NOT_RUN'; reason='UPSTREAM_PREPARE_PROFILE_CAN_WRITE' } }
        workspace=Get-XQWorkspaceRisk $WorkspacePath; launcherSummary=[pscustomobject][ordered]@{ status='NOT_AVAILABLE'; code=$null; message=$null }
    }
    if (-not (Test-XQDiagnosticObject $report)) { throw [InvalidOperationException]::new('Diagnostic schema contract rejected the report.') }
    $first = $report | ConvertTo-Json -Depth 12 -Compress
    $second = (Protect-XQSensitiveText -Text $first).Evidence.Text
    if (-not (Test-XQSerializedDiagnosticSafety $second)) { throw [InvalidOperationException]::new('Serialized diagnostic report contains sensitive text.') }
    Write-XQNewDiagnosticReport -Path $OutputPath -Text $second
    Write-Output $second
    exit 0
} catch {
    # Never emit exception text: paths and lower-layer messages can be sensitive.
    [Console]::Error.WriteLine('[DIAGNOSTIC_WRITE_REFUSED] No report was written.')
    exit 2
}

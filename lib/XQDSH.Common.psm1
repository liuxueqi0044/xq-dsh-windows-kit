Set-StrictMode -Version 2.0

function New-XQCheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][ValidateSet('INFO','WARNING','BLOCKER','ERROR','UNKNOWN')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        $Evidence = $null
    )
    [pscustomobject][ordered]@{ Passed = $Passed; Severity = $Severity; Code = $Code; Message = $Message; Evidence = $Evidence }
}

function Get-XQObjectValue {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-XQExactPropertySet {
    param($Object, [Parameter(Mandatory = $true)][string[]]$Names)
    if ($null -eq $Object) { return $false }
    $actual = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    return (@($actual | Where-Object { $Names -notcontains $_ }).Count -eq 0 -and
        @($Names | Where-Object { $actual -notcontains $_ }).Count -eq 0)
}

function Read-XQProductManifest {
    [CmdletBinding()]
    param([string]$ManifestPath = (Join-Path $PSScriptRoot '..\manifest\product-manifest.json'))
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { return New-XQCheckResult $false 'ERROR' 'MANIFEST_PATH_INVALID' 'Manifest path is empty.' $null }
    try {
        $item = Get-Item -LiteralPath $ManifestPath -ErrorAction Stop
        if ($item.PSIsContainer) { return New-XQCheckResult $false 'ERROR' 'MANIFEST_PATH_INVALID' 'Manifest path must be a file.' $null }
        $raw = [System.IO.File]::ReadAllText($item.FullName, [System.Text.Encoding]::UTF8)
        $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
        return New-XQCheckResult $true 'INFO' 'MANIFEST_READ' 'Product manifest was read.' ([pscustomobject]@{ Path = $item.FullName; Manifest = $manifest })
    } catch [System.Management.Automation.ItemNotFoundException] {
        return New-XQCheckResult $false 'ERROR' 'MANIFEST_NOT_FOUND' 'Product manifest was not found.' ([pscustomobject]@{ Path = $ManifestPath })
    } catch {
        return New-XQCheckResult $false 'ERROR' 'MANIFEST_INVALID_JSON' 'Product manifest is unreadable or invalid JSON.' ([pscustomobject]@{ Path = $ManifestPath })
    }
}

function Test-XQManifestRuntimePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Manifest)
    if ($Manifest -and $Manifest.PSObject.Properties['Evidence'] -and $Manifest.Evidence -and $Manifest.Evidence.PSObject.Properties['Manifest']) { $Manifest = $Manifest.Evidence.Manifest }
    if ($null -eq $Manifest) { return New-XQCheckResult $false 'ERROR' 'MANIFEST_MISSING' 'Product manifest is required.' $null }
    $product = Get-XQObjectValue $Manifest 'product'
    $upstream = Get-XQObjectValue $Manifest 'upstream'
    $runtime = Get-XQObjectValue $Manifest 'runtime'
    $privacy = Get-XQObjectValue $Manifest 'privacy'
    $release = Get-XQObjectValue $Manifest 'release'
    $git = Get-XQObjectValue $upstream 'git'
    $license = Get-XQObjectValue $upstream 'license'
    $package = Get-XQObjectValue $upstream 'packageName'
    $version = Get-XQObjectValue $upstream 'version'
    $registry = Get-XQObjectValue $upstream 'registry'
    $host = Get-XQObjectValue $runtime 'webHost'
    $port = Get-XQObjectValue $runtime 'webPort'
    $nodeRange = Get-XQObjectValue $runtime 'nodeRange'
    $sandbox = Get-XQObjectValue $runtime 'sandbox'
    $approval = Get-XQObjectValue $runtime 'approval'
    $telemetry = Get-XQObjectValue $privacy 'xqTelemetry'
    $issues = @()
    if (-not (Test-XQExactPropertySet $Manifest @('$schema','product','upstream','runtime','privacy','release'))) { $issues += 'manifestFields' }
    if (-not (Test-XQExactPropertySet $product @('name','version','brandClaimsVersion')) -or (Get-XQObjectValue $product 'name') -ne 'XQ DSH Windows Kit' -or (Get-XQObjectValue $product 'version') -ne '1.0.0') { $issues += 'product' }
    if (-not (Test-XQExactPropertySet $upstream @('packageName','version','registry','tarball','integrity','sha256','git','license'))) { $issues += 'upstreamFields' }
    if (-not (Test-XQExactPropertySet $git @('repository','tag','commit'))) { $issues += 'gitFields' }
    if (-not (Test-XQExactPropertySet $license @('spdx','url','sha256'))) { $issues += 'licenseFields' }
    if (-not (Test-XQExactPropertySet $runtime @('operatingSystem','architecture','nodeRange','webHost','webPort','sandbox','approval'))) { $issues += 'runtimeFields' }
    if (-not (Test-XQExactPropertySet $privacy @('xqTelemetry','diagnosticsUpload','sessionUpload'))) { $issues += 'privacyFields' }
    if (-not (Test-XQExactPropertySet $release @('state','lockedAtUtc','requiredGates','approvalReference','gateEvidence'))) { $issues += 'releaseFields' }
    if ($package -ne '@deepseek-ai/dsh') { $issues += 'package' }
    if ($version -ne '0.1.1-rc.2') { $issues += 'version' }
    if ($registry -ne 'https://registry.npmjs.org/') { $issues += 'registry' }
    if ((Get-XQObjectValue $upstream 'tarball') -ne 'https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.1-rc.2.tgz') { $issues += 'tarball' }
    if ((Get-XQObjectValue $upstream 'integrity') -ne 'sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg==') { $issues += 'integrity' }
    if ((Get-XQObjectValue $upstream 'sha256') -ne '47ec05f45ada5ab87779ae18a90456b5ebff5421dc0ff5c179677d65e1c16057') { $issues += 'sha256' }
    if ((Get-XQObjectValue $git 'repository') -ne 'https://github.com/deepseek-ai/deepseek-harness.git' -or (Get-XQObjectValue $git 'tag') -ne 'dsh-v0.1.1-rc.2' -or (Get-XQObjectValue $git 'commit') -ne 'b150a551b8d465e31e418e1b2eaf5e79bbb7d28e') { $issues += 'git' }
    if ((Get-XQObjectValue $license 'spdx') -ne 'MIT' -or (Get-XQObjectValue $license 'url') -ne 'https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.2/LICENSE' -or (Get-XQObjectValue $license 'sha256') -ne 'ebb4f09972aee8608be255debaf78451a68e95c290f55c240dec2ecfa16ea6be') { $issues += 'license' }
    if ((Get-XQObjectValue $runtime 'operatingSystem') -ne 'Windows 11' -or (Get-XQObjectValue $runtime 'architecture') -ne 'x64') { $issues += 'platform' }
    if ($host -ne '127.0.0.1') { $issues += 'host' }
    if ($port -ne 3080) { $issues += 'port' }
    if ($nodeRange -ne '>=22.19.0 <23.0.0 || >=24.0.0 <25.0.0') { $issues += 'nodeRange' }
    if ($sandbox -ne 'workspace-write') { $issues += 'defaultSandbox' }
    if ($approval -ne 'ask') { $issues += 'defaultApproval' }
    if ($telemetry -ne $false -or (Get-XQObjectValue $privacy 'diagnosticsUpload') -ne $false -or (Get-XQObjectValue $privacy 'sessionUpload') -ne $false) { $issues += 'xqTelemetry' }
    if ($issues.Count -gt 0) { return New-XQCheckResult $false 'ERROR' 'MANIFEST_RUNTIME_POLICY_INVALID' 'Manifest runtime policy is invalid.' ([pscustomobject]@{ InvalidFields = $issues }) }
    New-XQCheckResult $true 'INFO' 'MANIFEST_RUNTIME_POLICY_VALID' 'Manifest runtime policy is valid.' ([pscustomobject]@{ Package = $package; Version = $version; Registry = $registry; Host = $host; Port = $port; NodeRange = $nodeRange; DefaultSandbox=$sandbox; DefaultApproval=$approval; XqTelemetry=$telemetry })
}

function ConvertTo-XQSemanticVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$VersionText)
    $match = [regex]::Match($VersionText.Trim(), '^[vV]?(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?<pre>-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z.-]+)?$')
    if (-not $match.Success) { return New-XQCheckResult $false 'ERROR' 'VERSION_INVALID' 'Version is not a supported semantic version.' ([pscustomobject]@{ Input = $VersionText }) }
    $pre = $match.Groups['pre'].Value
    New-XQCheckResult $true 'INFO' 'VERSION_PARSED' 'Version was parsed.' ([pscustomobject]@{ Major = [int]$match.Groups['major'].Value; Minor = [int]$match.Groups['minor'].Value; Patch = [int]$match.Groups['patch'].Value; PreRelease = $pre; Normalized = ('{0}.{1}.{2}{3}' -f $match.Groups['major'].Value,$match.Groups['minor'].Value,$match.Groups['patch'].Value,$pre) })
}

function Test-XQSupportedNodeVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$VersionText, [string]$SupportedRange = '>=22.19.0 <23.0.0 || >=24.0.0 <25.0.0')
    if ($SupportedRange -ne '>=22.19.0 <23.0.0 || >=24.0.0 <25.0.0') { return New-XQCheckResult $false 'ERROR' 'NODE_RANGE_INVALID' 'Node support range is not an approved runtime policy.' ([pscustomobject]@{ Range = $SupportedRange }) }
    $parsed = ConvertTo-XQSemanticVersion $VersionText
    if (-not $parsed.Passed -or -not [string]::IsNullOrEmpty($parsed.Evidence.PreRelease)) { return New-XQCheckResult $false 'BLOCKER' 'NODE_VERSION_UNSUPPORTED' 'Node version is unsupported.' ([pscustomobject]@{ Input = $VersionText }) }
    $v = $parsed.Evidence
    $ok = (($v.Major -eq 22 -and (($v.Minor -gt 19) -or ($v.Minor -eq 19 -and $v.Patch -ge 0))) -or $v.Major -eq 24)
    if ($ok) { return New-XQCheckResult $true 'INFO' 'NODE_VERSION_SUPPORTED' 'Node version is supported.' $v }
    New-XQCheckResult $false 'BLOCKER' 'NODE_VERSION_UNSUPPORTED' 'Node version is outside the approved 22.19+ or 24.x LTS range.' $v
}

function Resolve-XQCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]'*?[') -ge 0) { return New-XQCheckResult $false 'ERROR' 'PATH_INVALID' 'Path must be non-empty, absolute, and contain no wildcard.' $null }
    if ($Path.StartsWith('\\')) { return New-XQCheckResult $false 'ERROR' 'PATH_NETWORK_DISALLOWED' 'UNC and network paths are not permitted.' ([pscustomobject]@{ Path = $Path }) }
    try {
        if (-not [System.IO.Path]::IsPathRooted($Path)) { return New-XQCheckResult $false 'ERROR' 'PATH_NOT_ABSOLUTE' 'Path must be absolute.' ([pscustomobject]@{ Path = $Path }) }
        $full = [System.IO.Path]::GetFullPath($Path)
        $provider = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($full)
        if ($provider -ne $full) { $full = $provider }
        $root = [System.IO.Path]::GetPathRoot($full)
        $canonical = if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) { $root } else { $full.TrimEnd('\\') }
        New-XQCheckResult $true 'INFO' 'PATH_RESOLVED' 'Path was canonicalized.' ([pscustomobject]@{ Path = $canonical; Exists = [System.IO.Directory]::Exists($canonical) })
    } catch { New-XQCheckResult $false 'ERROR' 'PATH_INVALID' 'Path cannot be resolved by the file system provider.' ([pscustomobject]@{ Path = $Path }) }
}

function Test-XQSafeWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$FirstRun)
    $resolved = Resolve-XQCanonicalPath $Path
    if (-not $resolved.Passed) { return $resolved }
    $full = $resolved.Evidence.Path
    $compare = [System.StringComparison]::OrdinalIgnoreCase
    $user = [Environment]::GetFolderPath('UserProfile').TrimEnd('\\')
    $windows = [Environment]::GetFolderPath('Windows').TrimEnd('\\')
    $desktop = [Environment]::GetFolderPath('Desktop').TrimEnd('\\')
    $documents = [Environment]::GetFolderPath('MyDocuments').TrimEnd('\\')
    $downloads = Join-Path $user 'Downloads'
    $root = [System.IO.Path]::GetPathRoot($full)
    $wide = @($root,$user,$windows,$desktop,$documents,$downloads)
    foreach ($entry in $wide) { if ($full.Equals($entry, $compare)) { return New-XQCheckResult $false 'BLOCKER' 'WORKSPACE_WIDE_PATH' 'Workspace is a prohibited broad directory.' ([pscustomobject]@{ Path = $full }) } }
    if ($full.StartsWith($windows + '\\', $compare)) { return New-XQCheckResult $false 'BLOCKER' 'WORKSPACE_SYSTEM_PATH' 'Workspace may not be inside the Windows system directory.' ([pscustomobject]@{ Path = $full }) }
    $cursor = $full
    while ($true) {
        # Test-Path can emit a terminating AccessDenied error for a junction when the
        # caller uses ErrorActionPreference=Stop.  The IO probes are deterministic and
        # let us inspect the reparse point itself instead of following it.
        if ([System.IO.Directory]::Exists($cursor) -or [System.IO.File]::Exists($cursor)) {
            try { $attrs = [System.IO.File]::GetAttributes($cursor); if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return New-XQCheckResult $false 'BLOCKER' 'WORKSPACE_REPARSE_POINT' 'Workspace path contains a reparse point.' ([pscustomobject]@{ Path = $cursor }) } } catch { return New-XQCheckResult $false 'ERROR' 'WORKSPACE_PATH_UNCHECKABLE' 'Workspace path metadata cannot be checked.' ([pscustomobject]@{ Path = $cursor }) }
        }
        $parent = [System.IO.Directory]::GetParent($cursor); if ($null -eq $parent -or $parent.FullName.Equals($cursor, $compare)) { break }; $cursor = $parent.FullName
    }
    if ([System.IO.Directory]::Exists($full) -and $FirstRun) {
        try { if ([System.IO.Directory]::EnumerateFileSystemEntries($full).GetEnumerator().MoveNext()) { return New-XQCheckResult $false 'BLOCKER' 'WORKSPACE_NOT_EMPTY' 'First-run workspace must be empty.' ([pscustomobject]@{ Path = $full }) } } catch { return New-XQCheckResult $false 'ERROR' 'WORKSPACE_UNENUMERABLE' 'Workspace metadata cannot be enumerated.' ([pscustomobject]@{ Path = $full }) }
    }
    New-XQCheckResult $true 'INFO' 'WORKSPACE_SAFE' 'Workspace path is a narrow candidate.' ([pscustomobject]@{ Path = $full; Exists = [System.IO.Directory]::Exists($full); FirstRun = [bool]$FirstRun })
}

function Test-XQLoopbackHost { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Host) if ($Host -ceq '127.0.0.1') { New-XQCheckResult $true 'INFO' 'HOST_LOOPBACK' 'Host is the required loopback address.' $Host } else { New-XQCheckResult $false 'BLOCKER' 'HOST_NOT_LOOPBACK' 'Only 127.0.0.1 is permitted.' $Host } }

function Get-XQPortState {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][ValidateRange(1,65535)][int]$Port)
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port }
        $pids = @()
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) { try { $pids = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique) } catch {} }
        $used = @($listeners).Count -gt 0
        New-XQCheckResult (-not $used) ($(if($used){'WARNING'}else{'INFO'})) ($(if($used){'PORT_IN_USE'}else{'PORT_AVAILABLE'})) ($(if($used){'Port is already listening.'}else{'Port is available.'})) ([pscustomobject]@{ Port=$Port; Listeners=@($listeners | ForEach-Object { $_.Address.ToString() }); ProcessIds=$pids })
    } catch { New-XQCheckResult $false 'UNKNOWN' 'PORT_CHECK_FAILED' 'Port state could not be determined.' ([pscustomobject]@{ Port=$Port }) }
}

function Get-XQCommandInfo {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name, [string[]]$Arguments = @('--version'), [int]$TimeoutSeconds = 8)
    if ([string]::IsNullOrWhiteSpace($Name) -or $TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60) { return New-XQCheckResult $false 'ERROR' 'COMMAND_INPUT_INVALID' 'Command name or timeout is invalid.' $null }
    try {
        $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = $cmd.Source; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        # Windows PowerShell/.NET Framework has no ProcessStartInfo.ArgumentList.  Arguments
        # are received as an array and quoted here solely for CreateProcess (never a shell).
        $quoted = foreach ($arg in $Arguments) { '"' + (([string]$arg) -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1') + '"' }
        $psi.Arguments = [string]::Join(' ', [string[]]$quoted)
        $process = New-Object System.Diagnostics.Process; $process.StartInfo = $psi; [void]$process.Start()
        # Begin both drains before waiting: this prevents a child that fills either redirected
        # pipe from deadlocking. Callers use only short, read-only status arguments.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch {}; return New-XQCheckResult $false 'UNKNOWN' 'COMMAND_TIMEOUT' 'Read-only command timed out and was stopped.' ([pscustomobject]@{ Name=$Name; Path=$cmd.Source }) }
        $raw = $stdoutTask.Result + $stderrTask.Result
        if ($raw.Length -gt 65536) { $raw = $raw.Substring(0,65536) + '[TRUNCATED]' }
        $out = Protect-XQSensitiveText $raw; New-XQCheckResult ($process.ExitCode -eq 0) ($(if($process.ExitCode -eq 0){'INFO'}else{'WARNING'})) 'COMMAND_EXECUTED' 'Read-only command completed.' ([pscustomobject]@{ Name=$Name; Path=$cmd.Source; ExitCode=$process.ExitCode; Output=$out.Evidence.Text })
    } catch { New-XQCheckResult $false 'WARNING' 'COMMAND_NOT_FOUND' 'Command was not found or could not be queried.' ([pscustomobject]@{ Name=$Name }) }
}

function Get-XQDshHomePath { [CmdletBinding()] param() $home = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh' }; Resolve-XQCanonicalPath $home }

function Protect-XQSensitiveText {
    [CmdletBinding()] param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return New-XQCheckResult $true 'INFO' 'TEXT_REDACTED' 'Text was redacted.' ([pscustomobject]@{ Text = $null; Redactions = @() }) }
    $rules = @(@('BEARER','(?i)(Authorization\s*:\s*Bearer\s+)[^\s,;]+','$1[REDACTED:BEARER]'),@('API_KEY','\bsk-[A-Za-z0-9_-]{8,}\b','[REDACTED:API_KEY]'),@('JWT','\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b','[REDACTED:JWT]'),@('URL_SECRET','(?i)([?&](?:token|key|secret|password|cookie)=[^&#\s]+)','$1'),@('URL_USERINFO','(?i)(https?://)[^/@\s:]+:[^/@\s]+@','$1[REDACTED:URL_USERINFO]@'),@('ASSIGNMENT','(?im)(\b(?:password|token|api[_-]?key|secret|cookie)\b\s*[:=]\s*)(?:"[^"\r\n]*"|''[^''\r\n]*''|[^\s,;]+)','$1[REDACTED:SECRET]'))
    $value = $Text; $found = @()
    foreach ($rule in $rules) { $before = $value; if ($rule[0] -eq 'URL_SECRET') { $value = [regex]::Replace($value,$rule[1],{ param($m) ($m.Value -replace '=.*$','=[REDACTED:URL_SECRET]') }) } else { $value = [regex]::Replace($value,$rule[1],$rule[2]) }; if ($value -ne $before) { $found += $rule[0] } }
    New-XQCheckResult $true 'INFO' 'TEXT_REDACTED' 'Text was redacted.' ([pscustomobject]@{ Text = $value; Redactions = @($found) })
}
function Test-XQSensitiveText { [CmdletBinding()] param([AllowNull()][string]$Text) $protected = Protect-XQSensitiveText $Text; New-XQCheckResult (($protected.Evidence.Redactions.Count -eq 0)) ($(if($protected.Evidence.Redactions.Count -eq 0){'INFO'}else{'WARNING'})) ($(if($protected.Evidence.Redactions.Count -eq 0){'TEXT_SAFE'}else{'TEXT_SENSITIVE'})) ($(if($protected.Evidence.Redactions.Count -eq 0){'No recognized sensitive text was found.'}else{'Recognized sensitive text was found.'})) $protected.Evidence }

Export-ModuleMember -Function New-XQCheckResult,Read-XQProductManifest,Test-XQManifestRuntimePolicy,ConvertTo-XQSemanticVersion,Test-XQSupportedNodeVersion,Resolve-XQCanonicalPath,Test-XQSafeWorkspace,Test-XQLoopbackHost,Get-XQPortState,Get-XQCommandInfo,Get-XQDshHomePath,Protect-XQSensitiveText,Test-XQSensitiveText

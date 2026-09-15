[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackagePath,
    [Parameter(Mandatory=$true)][string]$ExpectedVersion,
    [Parameter(Mandatory=$true)][string]$ExpectedIntegrity,
    [Parameter(Mandatory=$true)][string]$Source
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\XQDSH.Common.psm1') -Force

function Add-XQPluginResult {
    param([System.Collections.ArrayList]$List,[bool]$Passed,[string]$Severity,[string]$Code,[string]$Message,$Evidence=$null)
    [void]$List.Add((New-XQCheckResult -Passed $Passed -Severity $Severity -Code $Code -Message $Message -Evidence $Evidence))
}

function Get-XQIntegrity {
    param([string]$Path,[string]$Algorithm)
    $hash = [Security.Cryptography.HashAlgorithm]::Create($Algorithm.ToUpperInvariant())
    if ($null -eq $hash) { throw 'unsupported-integrity-algorithm' }
    $stream = [IO.File]::OpenRead($Path)
    try { return [Convert]::ToBase64String($hash.ComputeHash($stream)) } finally { $stream.Dispose(); $hash.Dispose() }
}

function Read-XQNpmTgz {
    param([Parameter(Mandatory=$true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Length -gt 52428800) { throw 'compressed-package-too-large' }
    $input = [IO.File]::OpenRead($item.FullName)
    $gzip = New-Object IO.Compression.GZipStream($input,[IO.Compression.CompressionMode]::Decompress)
    $memory = New-Object IO.MemoryStream
    $buffer = New-Object byte[] 65536
    try {
        while (($read = $gzip.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt 104857600) { throw 'expanded-package-too-large' }
            $memory.Write($buffer,0,$read)
        }
    } finally { $gzip.Dispose(); $input.Dispose() }
    $bytes = $memory.ToArray(); $memory.Dispose()
    $offset = 0; $entries = New-Object System.Collections.Generic.List[object]; $packageJson = $null
    while ($offset + 512 -le $bytes.Length) {
        $name = ([Text.Encoding]::ASCII.GetString($bytes,$offset,100)).Trim([char]0)
        if ([string]::IsNullOrEmpty($name)) { break }
        if ($entries.Count -ge 5000) { throw 'too-many-tar-entries' }
        $sizeText = ([Text.Encoding]::ASCII.GetString($bytes,$offset + 124,12)).Trim([char]0,' ')
        if ($sizeText -notmatch '^[0-7]*$') { throw 'invalid-tar-size' }
        $size = if ([string]::IsNullOrWhiteSpace($sizeText)) { [int64]0 } else { [Convert]::ToInt64($sizeText,8) }
        $typeFlag = [char]$bytes[$offset + 156]
        if ($name -match '(^|/)\.\.(/|$)' -or $name -match '^[\\/]' -or $name -match '^[A-Za-z]:' -or $name.Contains('\')) { throw 'unsafe-tar-path' }
        if (-not ($name -eq 'package' -or $name.StartsWith('package/'))) { throw 'tar-entry-outside-package-root' }
        if ($typeFlag -eq '1' -or $typeFlag -eq '2') { throw 'tar-link-entry-not-eligible' }
        $dataStart = $offset + 512
        if ($size -lt 0 -or $dataStart + $size -gt $bytes.Length) { throw 'truncated-tar-entry' }
        [void]$entries.Add([pscustomobject]@{Name=$name;Size=$size;Type=[string]$typeFlag})
        if ($name -eq 'package/package.json') {
            if ($size -gt 524288) { throw 'package-json-too-large' }
            $packageJson = [Text.Encoding]::UTF8.GetString($bytes,$dataStart,[int]$size)
        }
        $offset = $dataStart + ([int64][Math]::Ceiling($size / 512.0) * 512)
    }
    if ($null -eq $packageJson) { throw 'package-json-missing' }
    $entryArray = @($entries | ForEach-Object { $_ })
    [pscustomobject]@{Package=($packageJson | ConvertFrom-Json -ErrorAction Stop);Entries=$entryArray}
}

$results = New-Object Collections.ArrayList
$package = $null; $entryText = ''
$integrityMatch = [regex]::Match($ExpectedIntegrity,'^sha(?<bits>256|384|512)-(?<digest>[A-Za-z0-9+/]+={0,2})$')
if (-not $integrityMatch.Success) { Add-XQPluginResult $results $false 'BLOCKER' 'INTEGRITY_REQUIRED' 'A syntactically valid expected npm integrity is required.' }
if ([string]::IsNullOrWhiteSpace($Source) -or $Source -notmatch '^https://registry\.npmjs\.org/.+\.tgz$') { Add-XQPluginResult $results $false 'BLOCKER' 'TARBALL_SOURCE_UNTRUSTED' 'A registry.npmjs.org tarball URL is required.' }

try {
    $item = Get-Item -LiteralPath $PackagePath -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        Add-XQPluginResult $results $false 'BLOCKER' 'INTEGRITY_UNVERIFIABLE' 'A pre-expanded directory cannot prove registry tarball integrity.'
        $packageFile = Join-Path $item.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $packageFile -PathType Leaf)) { throw 'package-json-missing' }
        $packageItem = Get-Item -LiteralPath $packageFile -Force
        if ($packageItem.Length -gt 524288) { throw 'package-json-too-large' }
        $package = [IO.File]::ReadAllText($packageItem.FullName,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $entryText = (@(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop | ForEach-Object { $_.FullName.Substring($item.FullName.Length).TrimStart('\','/') }) -join "`n")
    } elseif ($item.Extension -ieq '.tgz') {
        if ($integrityMatch.Success) {
            $actual = Get-XQIntegrity -Path $item.FullName -Algorithm ('SHA' + $integrityMatch.Groups['bits'].Value)
            if ($actual -cne $integrityMatch.Groups['digest'].Value) { Add-XQPluginResult $results $false 'BLOCKER' 'INTEGRITY_MISMATCH' 'Package bytes do not match expected integrity.' }
        }
        $archive = Read-XQNpmTgz -Path $item.FullName
        $package = $archive.Package
        $entryText = (@($archive.Entries | ForEach-Object {$_.Name}) -join "`n")
    } else { throw 'unsupported-package-kind' }
} catch {
    Add-XQPluginResult $results $false 'BLOCKER' 'PACKAGE_UNREADABLE' 'Package metadata cannot be safely read.'
}

if ($null -ne $package) {
    if ($ExpectedVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$' -or [string]$package.version -cne $ExpectedVersion) { Add-XQPluginResult $results $false 'BLOCKER' 'EXACT_VERSION_REQUIRED' 'Exact requested version is absent or does not match package.json.' }
    if ([string]::IsNullOrWhiteSpace([string]$package.license)) { Add-XQPluginResult $results $false 'BLOCKER' 'LICENSE_UNKNOWN' 'Package license is required.' }
    $scriptsProperty = $package.PSObject.Properties['scripts']
    if ($null -ne $scriptsProperty -and $null -ne $scriptsProperty.Value) {
        foreach ($scriptName in @('preinstall','install','postinstall','prepare')) {
            if ($null -ne $scriptsProperty.Value.PSObject.Properties[$scriptName]) { Add-XQPluginResult $results $false 'BLOCKER' 'LIFECYCLE_SCRIPT_PRESENT' "Lifecycle script $scriptName is not eligible." }
        }
    }
    foreach ($dependencyMap in @('dependencies','optionalDependencies','peerDependencies')) {
        $property = $package.PSObject.Properties[$dependencyMap]
        if ($null -ne $property -and $null -ne $property.Value -and @($property.Value.PSObject.Properties).Count -gt 0) { Add-XQPluginResult $results $false 'BLOCKER' 'DEPENDENCY_CLOSURE_UNRESOLVED' 'Dependency closure cannot be proven from the root package alone.' $dependencyMap }
    }
    if ($entryText -match '(?i)\.(node|dll|exe)(?:\r?$|\n)') { Add-XQPluginResult $results $false 'BLOCKER' 'NATIVE_BINARY' 'Native binaries are out of scope.' }
    $raw = $package | ConvertTo-Json -Depth 20
    if ($raw -match '(?i)(allowBuilds|puppeteer|playwright)') { Add-XQPluginResult $results $false 'BLOCKER' 'ALLOWBUILDS_OR_BROWSER_DRIVER' 'Build permissions or browser drivers are out of scope.' }
    if ($raw -match '(?i)(oauth|openid|stripe|paid[ ._-]?api|subscription)') { Add-XQPluginResult $results $false 'BLOCKER' 'OAUTH_OR_PAID_API' 'OAuth or paid APIs are out of scope.' }
    if ($raw -match '(?i)(listen\s*\(|createServer|windows service|background service|0\.0\.0\.0)') { Add-XQPluginResult $results $false 'BLOCKER' 'SERVICE_OR_PUBLIC_LISTENER' 'Services or public listeners are out of scope.' }
}

if (@($results).Count -eq 0) { Add-XQPluginResult $results $true 'INFO' 'PLUGIN_STATIC_CHECKS_PASSED' 'Artifact is a candidate only; compatibility and VM validation remain PENDING.' }
$passed = @($results | Where-Object {-not $_.Passed}).Count -eq 0
[pscustomobject]@{Passed=$passed;Classification=$(if($passed){'simple-paid-addon-eligible'}else{'out-of-scope'});VmValidation='PENDING';Results=@($results)}

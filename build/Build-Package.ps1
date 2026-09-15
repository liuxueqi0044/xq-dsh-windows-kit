[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutputRoot,
    [switch]$Candidate,
    [string]$PreBuildGatePath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $Root 'dist' }

function Test-XQPackageRelativePath { param([string]$Path)
    return (-not [string]::IsNullOrWhiteSpace($Path) -and $Path -notmatch '^(?:[A-Za-z]:|/|\\)' -and $Path -notmatch '(^|[\\/])\.\.([\\/]|$)' -and $Path -notmatch '(^|[\\/])(?:extensions|tests|acceptance|docs|build|node_modules|\.git)([\\/]|$)')
}
function Get-XQFileHashText { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-XQInputCommit { param([string]$RepositoryRoot)
    # CI supplies an immutable commit explicitly. Local source snapshots without
    # such an input are recorded as unavailable rather than probing git state.
    if ($env:GITHUB_SHA -match '^[0-9a-fA-F]{40}$') { return [string]$env:GITHUB_SHA }
    return 'UNAVAILABLE'
}
function Test-XQSensitivePackageFile { param([string]$Relative,[string]$Path)
    if ($Relative -match '(?i)(^|[\\/])\.env(?:$|\.)|(?:^|[\\/])(node_modules|cache|staging|sessions?|workspace)(?:[\\/]|$)|\.(?:pem|pfx|key)$|(?:^|[\\/])(?:id_rsa|cookies?)') { return $false }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    return ($text -notmatch '(?i)Authorization\s*:\s*Bearer\s+(?!\[REDACTED:BEARER\])\S+' -and $text -notmatch '\bsk-[A-Za-z0-9_-]{8,}\b' -and $text -notmatch '\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b' -and $text -notmatch '(?im)\b(?:password|token|api[_-]?key|secret|cookie)\b\s*[:=]\s*(?!\[REDACTED:SECRET\])[^\s,;]+')
}
function Remove-XQBuildPath { param([string]$Path,[string]$TempRoot)
    $full = [IO.Path]::GetFullPath($Path); $base = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\','/')
    if ($full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}
function Test-XQGateRelativePath { param([string]$Path)
    return (-not [string]::IsNullOrWhiteSpace($Path) -and $Path -notmatch '^(?:[A-Za-z]:|/|\\)' -and $Path -notmatch '(^|[\\/])\.\.([\\/]|$)')
}
function Assert-XQCandidateGate {
    param([string]$Path,[string]$ManifestHash,[string]$RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { throw 'Candidate build requires an M10 pre-build gate result.' }
    $gate = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($gate.schema -ne 'xq.m10.prebuild-gate.v1' -or $gate.scope -ne 'M10-PREBUILD' -or $gate.status -ne 'PASS' -or $gate.manifestSha256 -cne $ManifestHash) { throw 'Candidate gate schema, scope, status, or manifest hash is invalid.' }
    if ([string]$gate.commit -notmatch '^[a-f0-9]{40}$') { throw 'Candidate gate does not identify an immutable input commit.' }
    try { $generated = [DateTimeOffset]::Parse([string]$gate.generatedAtUtc) } catch { throw 'Candidate gate time is invalid.' }
    if ($generated -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { throw 'Candidate gate time is in the future.' }
    $observationRelative = [string]$gate.sourceObservationPath
    if (-not (Test-XQGateRelativePath $observationRelative) -or $observationRelative.Replace('\','/') -notmatch '^tests/results/') { throw 'Candidate gate source observation path is invalid.' }
    if ([string]$gate.sourceObservationSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Candidate gate source observation hash is incomplete.' }
    $observationPath = Join-Path $RepositoryRoot $observationRelative
    if (-not [IO.File]::Exists($observationPath) -or (Get-XQFileHashText $observationPath) -cne ([string]$gate.sourceObservationSha256).ToLowerInvariant()) { throw 'Candidate gate source observation hash is invalid.' }
    $sourceObservation = [IO.File]::ReadAllText($observationPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($sourceObservation.status -ne 'PASS' -or $null -eq $sourceObservation.checks -or @($sourceObservation.checks.PSObject.Properties | Where-Object { $_.Value -ne $true }).Count -ne 0) { throw 'Official source observation is not a complete PASS.' }
    $results = @($gate.results)
    if ($results.Count -eq 0 -or @($results | Where-Object { $_.status -ne 'PASS' }).Count -ne 0) { throw 'Candidate gate contains a non-passing pre-build result.' }
    return $gate
}
function Remove-XQPublishedOutput { param([string]$Path,[string]$OutputRoot)
    $full = [IO.Path]::GetFullPath($Path); $base = [IO.Path]::GetFullPath($OutputRoot)
    if ($full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}
function New-XQDeterministicZip { param([string]$Source,[string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = New-Object IO.FileStream($ZipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $stamp = [DateTimeOffset]([DateTime]::SpecifyKind([datetime]'1980-01-01T00:00:00',[DateTimeKind]::Utc))
            foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File | Sort-Object { $_.FullName.Substring($Source.Length).Replace('\','/') })) {
                $name = $file.FullName.Substring($Source.Length).TrimStart('\','/').Replace('\','/')
                if ($name -match '(^|/)\.\.(/|$)|^[A-Za-z]:|^/') { throw 'Unsafe ZIP entry path.' }
                $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal); $entry.LastWriteTime = $stamp
                $input = [IO.File]::OpenRead($file.FullName); $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('xq-m09-' + [guid]::NewGuid().ToString('N'))
$createdOutputs = @(); $out = $null; $createdOutputRoot = $false; $candidateGate = $null
try {
    $layoutPath = Join-Path $Root 'build/package-layout.json'; $manifestPath = Join-Path $Root 'manifest/product-manifest.json'
    if (-not [IO.File]::Exists($layoutPath) -or -not [IO.File]::Exists($manifestPath)) { throw 'Build inputs are missing.' }
    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.release.state -eq 'releasable') { throw 'M09 cannot package a self-declared releasable manifest.' }
    $manifestHash = Get-XQFileHashText $manifestPath
    if ($Candidate) { $candidateGate = Assert-XQCandidateGate -Path $PreBuildGatePath -ManifestHash $manifestHash -RepositoryRoot $Root }
    $layout = [IO.File]::ReadAllText($layoutPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($layout.'$schema' -ne 'package-layout/v1' -or [string]::IsNullOrWhiteSpace($layout.packageRoot)) { throw 'Package layout is invalid.' }
    $seen = @{}; $contentFiles = @()
    foreach ($entry in @($layout.files)) {
        $source = if ($null -ne $entry.PSObject.Properties['source']) { [string]$entry.source } else { '' }; $destination = [string]$entry.destination; $generated = if ($null -ne $entry.PSObject.Properties['generated']) { [string]$entry.generated } else { '' }
        if (-not (Test-XQPackageRelativePath $destination) -or $seen.ContainsKey($destination) -or (($generated -notin @('source-and-version','internal-sha256sums')) -and -not (Test-XQPackageRelativePath $source))) { throw 'Package layout contains an unsafe or duplicate path.' }
        $seen[$destination] = $true
        if ($generated -in @('source-and-version','internal-sha256sums')) { continue }
        if (-not [IO.File]::Exists((Join-Path $Root $source))) { throw 'A whitelisted source file is missing.' }
        if ($source -match '^content[\\/]') { $contentFiles += $entry }
    }
    $packageName = [string]$layout.packageRoot; $stage = Join-Path (Join-Path $tempRoot 'work') $packageName; [void][IO.Directory]::CreateDirectory($stage)
    & (Join-Path $Root 'build/Render-OfflineContent.ps1') -SourceRoot $Root -DestinationRoot $stage -Files $contentFiles
    foreach ($entry in @($layout.files | Where-Object { ($null -eq $_.PSObject.Properties['source'] -or $_.source -notmatch '^content[\\/]') -and ($null -eq $_.PSObject.Properties['generated'] -or $_.generated -notin @('source-and-version','internal-sha256sums')) })) {
        $target = Join-Path $stage ([string]$entry.destination); $parent = Split-Path -Parent $target
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        [IO.File]::Copy((Join-Path $Root ([string]$entry.source)), $target, $false)
        if ([string]$entry.source -match '^(?:launcher[\\/](?:Test-XQDSHEnvironment|Start-XQDSH)\.ps1|diagnostics[\\/]XQ-DSH-Diagnose\.ps1)$') {
            $scriptText = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
            $scriptText = $scriptText.Replace('..\lib\XQDSH.Common.psm1','..\_internal\lib\XQDSH.Common.psm1').Replace('..\manifest\product-manifest.json','..\_internal\manifest\product-manifest.json')
            if ([string]$entry.source -match '^launcher[\\/]Start-XQDSH\.ps1$') { $scriptText = $scriptText.Replace("Join-Path `$PSScriptRoot 'XQ-DSH-Safe.patch.yml'","Join-Path `$PSScriptRoot '..\_internal\launcher\XQ-DSH-Safe.patch.yml'") }
            # Windows PowerShell 5.1 treats UTF-8 without BOM as the active ANSI code
            # page.  Preserve a BOM after rewriting so Chinese paths/comments remain safe.
            [IO.File]::WriteAllText($target, $scriptText, (New-Object Text.UTF8Encoding($true)))
        }
    }
    $sourceVersion = [pscustomobject][ordered]@{ product=$manifest.product; upstream=$manifest.upstream; generatedFrom='manifest/product-manifest.json' }
    $sourceVersionRelative = [string](@($layout.files | Where-Object { $null -ne $_.PSObject.Properties['generated'] -and $_.generated -eq 'source-and-version' })[0].destination)
    $sourceVersionPath = Join-Path $stage $sourceVersionRelative; [IO.File]::WriteAllText($sourceVersionPath, ($sourceVersion | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding($false)))
    $packageFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
    foreach ($file in $packageFiles) { $relative = $file.FullName.Substring($stage.Length).TrimStart('\','/').Replace('\','/'); if (-not (Test-XQSensitivePackageFile $relative $file.FullName)) { throw 'Sensitive or prohibited package content was detected.' } }
    $hashLines = @($packageFiles | Sort-Object { $_.FullName.Substring($stage.Length).Replace('\','/') } | ForEach-Object { '{0}  {1}' -f (Get-XQFileHashText $_.FullName), $_.FullName.Substring($stage.Length).TrimStart('\','/').Replace('\','/') })
    $internalSumRelative = [string](@($layout.files | Where-Object { $null -ne $_.PSObject.Properties['generated'] -and $_.generated -eq 'internal-sha256sums' })[0].destination); [IO.File]::WriteAllLines((Join-Path $stage $internalSumRelative), [string[]]$hashLines, (New-Object Text.UTF8Encoding($false)))
    $publish = Join-Path $tempRoot 'publish'; [void][IO.Directory]::CreateDirectory($publish)
    $publishedDirectory = Join-Path $publish $packageName; [IO.Directory]::Move($stage,$publishedDirectory)
    $zipPath = Join-Path $publish ($packageName + '.zip'); $releasePath = Join-Path $publish 'release-manifest.json'; $sumPath = Join-Path $publish 'SHA256SUMS.txt'; $reportPath = Join-Path $publish 'build-report.json'
    New-XQDeterministicZip -Source $publishedDirectory -ZipPath $zipPath
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath); try { foreach ($entry in @($zip.Entries)) { if ($entry.FullName -match '(^|/)\.\.(/|$)|^[A-Za-z]:|^/' -or -not $seen.ContainsKey($entry.FullName)) { throw 'ZIP re-scan rejected an entry.' } } } finally { $zip.Dispose() }
    $zipHash = Get-XQFileHashText $zipPath
    [IO.File]::WriteAllText($sumPath,('{0}  {1}' -f $zipHash,[IO.Path]::GetFileName($zipPath)),(New-Object Text.UTF8Encoding($false)))
    $release = [pscustomobject][ordered]@{ schemaVersion='1'; package=$packageName; buildKind=$(if($Candidate){'candidate'}else{'development'}); productReleaseState=$manifest.release.state; zipFile=[IO.Path]::GetFileName($zipPath); zipSha256=$zipHash; zipBytes=(Get-Item -LiteralPath $zipPath).Length; selfReference=$false }
    $reportCommit = if($Candidate){[string]$candidateGate.commit}else{Get-XQInputCommit $Root}
    $report = [pscustomobject][ordered]@{ schemaVersion='1'; tool='Build-Package.ps1'; powershellVersion=$PSVersionTable.PSVersion.ToString(); inputCommit=$reportCommit; gates=[pscustomobject]@{ manifest='PASS'; layout='PASS'; offlineContent='PASS'; sensitiveScan='PASS'; preBuild=$(if($Candidate){'PASS'}else{'NOT_SUPPLIED'}); m11='PENDING' }; buildKind=$release.buildKind }
    [IO.File]::WriteAllText($releasePath, ($release | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
    $out = [IO.Path]::GetFullPath($OutputRoot)
    if (-not [IO.Directory]::Exists($out)) { [void][IO.Directory]::CreateDirectory($out); $createdOutputRoot = $true }
    $finalDirectory = Join-Path $out $packageName; $finalZip = Join-Path $out ([IO.Path]::GetFileName($zipPath)); $finalRelease = Join-Path $out 'release-manifest.json'; $finalSum = Join-Path $out 'SHA256SUMS.txt'; $finalReport = Join-Path $out 'build-report.json'
    foreach ($path in @($finalDirectory,$finalZip,$finalRelease,$finalSum,$finalReport)) { if (Test-Path -LiteralPath $path) { throw 'Output already exists; formal artifacts are never overwritten.' } }
    foreach ($pair in @(@($publishedDirectory,$finalDirectory),@($zipPath,$finalZip),@($releasePath,$finalRelease),@($sumPath,$finalSum),@($reportPath,$finalReport))) { Move-Item -LiteralPath $pair[0] -Destination $pair[1] -ErrorAction Stop; $createdOutputs += $pair[1] }
    Write-Output ($release | ConvertTo-Json -Depth 6 -Compress)
    exit 0
} catch {
    foreach ($path in @($createdOutputs)) { Remove-XQPublishedOutput -Path $path -OutputRoot $out }
    if ($createdOutputRoot -and $null -ne $out -and [IO.Directory]::Exists($out) -and -not [IO.Directory]::EnumerateFileSystemEntries($out).GetEnumerator().MoveNext()) { Remove-XQPublishedOutput -Path $out -OutputRoot (Split-Path -Parent $out) }
    [Console]::Error.WriteLine('[PACKAGE_BUILD_REFUSED] No artifact was published.'); exit 3
}
finally { if ([IO.Directory]::Exists($tempRoot)) { Remove-XQBuildPath -Path $tempRoot -TempRoot ([IO.Path]::GetTempPath()) } }

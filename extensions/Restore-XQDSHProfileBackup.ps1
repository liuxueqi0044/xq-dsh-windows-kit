[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProfilePath,
    [Parameter(Mandatory=$true)][string]$BackupPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [Parameter(Mandatory=$true)][ValidateSet('RESTORE')][string]$ConfirmRestore
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-XQFullDirectoryPath { param([string]$Path) [IO.Path]::GetFullPath($Path).TrimEnd('\','/') }
function Test-XQSameOrChildPath {
    param([string]$Parent,[string]$Candidate)
    $parentFull = Get-XQFullDirectoryPath $Parent
    $candidateFull = Get-XQFullDirectoryPath $Candidate
    return ($candidateFull -eq $parentFull -or $candidateFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))
}

$profile = Get-XQFullDirectoryPath $ProfilePath
$backup = Get-XQFullDirectoryPath $BackupPath
if ($profile -eq [IO.Path]::GetPathRoot($profile) -or $profile -eq (Get-XQFullDirectoryPath ([Environment]::GetFolderPath('UserProfile')))) { throw 'Profile path is too broad.' }
if (-not (Test-Path -LiteralPath $backup -PathType Container)) { throw 'Backup directory is missing.' }
if ((Test-XQSameOrChildPath $profile $backup) -or (Test-XQSameOrChildPath $backup $profile)) { throw 'Profile and backup paths must be disjoint.' }

$manifestPath = Join-Path $backup 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Backup manifest is missing.' }
$actualManifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
if ($actualManifestHash -cne $ExpectedManifestSha256.ToLowerInvariant()) { throw 'Backup manifest hash does not match the approved value.' }
$manifest = [IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
if ([string]$manifest.schemaVersion -cne '1.0' -or (Get-XQFullDirectoryPath ([string]$manifest.profilePath)) -cne $profile) { throw 'Backup manifest targets a different profile.' }

$seen = @{}
foreach ($file in @($manifest.files)) {
    $relative = [string]$file.path
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $seen.ContainsKey($relative.ToLowerInvariant())) { throw 'Unsafe or duplicate manifest path.' }
    $seen[$relative.ToLowerInvariant()] = $true
    $source = [IO.Path]::GetFullPath((Join-Path $backup ($relative -replace '/','\')))
    if (-not (Test-XQSameOrChildPath $backup $source) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Backup entry is missing or outside the backup root.' }
    $sourceItem = Get-Item -LiteralPath $source -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Backup entry is a reparse point.' }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant() -cne [string]$file.sha256) { throw 'Backup entry hash verification failed.' }
    if ($null -ne $file.PSObject.Properties['size'] -and [int64]$file.size -ne [int64]$sourceItem.Length) { throw 'Backup entry size verification failed.' }
}

$parent = [IO.Path]::GetDirectoryName($profile)
if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Profile parent directory must already exist.' }
$stage = Join-Path $parent ('.xq-restore-' + [guid]::NewGuid().ToString('N'))
$previous = Join-Path $parent ('.xq-previous-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
$movedPrevious = $false; $activated = $false
try {
    foreach ($file in @($manifest.files)) {
        $relative = ([string]$file.path) -replace '/','\'
        $source = Join-Path $backup $relative
        $target = Join-Path $stage $relative
        $targetDirectory = [IO.Path]::GetDirectoryName($target)
        if (-not [string]::IsNullOrWhiteSpace($targetDirectory)) { [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null }
        [IO.File]::Copy($source,$target,$false)
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant() -cne [string]$file.sha256) { throw 'Staged restore verification failed.' }
    }
    if (Test-Path -LiteralPath $profile) { [IO.Directory]::Move($profile,$previous); $movedPrevious = $true }
    [IO.Directory]::Move($stage,$profile); $activated = $true
    $previousRetained = $false
    if ($movedPrevious -and (Test-Path -LiteralPath $previous)) {
        try { Remove-Item -LiteralPath $previous -Recurse -Force -ErrorAction Stop } catch { $previousRetained = $true }
    }
    [pscustomobject]@{Restored=$true;FileCount=@($manifest.files).Count;Verification='PASS';PreviousProfileRetained=$previousRetained;PreviousProfilePath=$(if($previousRetained){$previous}else{$null})}
} catch {
    if (-not $activated -and $movedPrevious -and -not (Test-Path -LiteralPath $profile) -and (Test-Path -LiteralPath $previous)) { [IO.Directory]::Move($previous,$profile) }
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProfilePath,
    [Parameter(Mandatory=$true)][string]$BackupRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-XQFullDirectoryPath { param([string]$Path) [IO.Path]::GetFullPath($Path).TrimEnd('\','/') }
function Test-XQSameOrChildPath {
    param([string]$Parent,[string]$Candidate)
    $prefix = (Get-XQFullDirectoryPath $Parent) + [IO.Path]::DirectorySeparatorChar
    $full = Get-XQFullDirectoryPath $Candidate
    return ($full -eq (Get-XQFullDirectoryPath $Parent) -or $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase))
}

$profile = Get-XQFullDirectoryPath $ProfilePath
$root = Get-XQFullDirectoryPath $BackupRoot
if (-not (Test-Path -LiteralPath $profile -PathType Container)) { throw 'Profile directory must exist.' }
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Backup root must exist.' }
if ((Test-XQSameOrChildPath $profile $root) -or (Test-XQSameOrChildPath $root $profile)) { throw 'Profile and backup root must be disjoint.' }
if ($profile -eq [IO.Path]::GetPathRoot($profile) -or $profile -eq (Get-XQFullDirectoryPath ([Environment]::GetFolderPath('UserProfile')))) { throw 'Profile path is too broad.' }

$sourceEntries = @(Get-ChildItem -LiteralPath $profile -Recurse -Force -ErrorAction Stop)
if (@($sourceEntries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) { throw 'Profile contains a reparse point; backup refused.' }
$sourceFiles = @($sourceEntries | Where-Object {-not $_.PSIsContainer} | Sort-Object FullName)
$destination = Join-Path $root ('xq-dsh-backup-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($destination) | Out-Null

try {
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($profile.Length).TrimStart('\','/')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe profile entry.' }
        $target = Join-Path $destination $relative
        $targetDirectory = [IO.Path]::GetDirectoryName($target)
        if (-not [string]::IsNullOrWhiteSpace($targetDirectory)) { [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null }
        [IO.File]::Copy($file.FullName,$target,$false)
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        if ($sourceHash -cne $targetHash) { throw 'Backup copy verification failed.' }
        [void]$files.Add([ordered]@{path=($relative -replace '\\','/');sha256=$targetHash;size=[int64]$file.Length})
    }
    $manifestFiles = @($files | ForEach-Object { $_ })
    $manifest = [ordered]@{schemaVersion='1.0';profilePath=$profile;createdAtUtc=[DateTime]::UtcNow.ToString('o');files=$manifestFiles}
    $manifestPath = Join-Path $destination 'manifest.json'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),$utf8)
    $manifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
    [pscustomobject]@{BackupPath=$destination;ManifestPath=$manifestPath;ManifestSha256=$manifestHash;FileCount=$files.Count}
} catch {
    if ((Test-Path -LiteralPath $destination) -and (Test-XQSameOrChildPath $root $destination)) { Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}

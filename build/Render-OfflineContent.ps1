[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceRoot,
    [Parameter(Mandatory=$true)][string]$DestinationRoot,
    [Parameter(Mandatory=$true)][object[]]$Files
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-XQOfflineHtml { param([string]$Text)
    if ($Text -match '(?is)<script|<iframe|<form|<meta[^>]+http-equiv\s*=\s*["'']?refresh|@import|url\s*\(') { return $false }
    if ($Text -match '(?i)\b(?:src|href)\s*=\s*["'']https?://') { return $false }
    if ($Text -match '(?i)(google-analytics|gtag\s*\(|pixel|doubleclick|facebook\.com/tr|<img)') { return $false }
    return $true
}
foreach ($map in @($Files | Sort-Object { [string]$_.source })) {
    $relative = [string]$map.source; $destination = [string]$map.destination
    if ($relative -notmatch '^content(?:/|\\)' -or [string]::IsNullOrWhiteSpace($destination)) { throw 'Only explicitly whitelisted content paths can be rendered.' }
    $source = Join-Path $SourceRoot $relative
    if (-not [IO.File]::Exists($source)) { throw 'Whitelisted offline content file is missing.' }
    $text = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)
    if ($source -match '\.html$' -and -not (Test-XQOfflineHtml $text)) { throw 'Offline content contains an active or remote construct.' }
    if ($source -match '\.html$') {
        foreach ($match in [regex]::Matches($text, '(?i)href\s*=\s*["'']([^"'']+)["'']')) {
            $link = $match.Groups[1].Value
            if ($link -notmatch '^#') {
                $part = $link.Split('#')[0]
                if ($part -match '^(?:https?:|//|mailto:)' -or -not [IO.File]::Exists((Join-Path (Split-Path -Parent $source) $part))) { throw 'Offline content has an unavailable navigation target.' }
            }
        }
    }
    $target = Join-Path $DestinationRoot $destination
    $parent = Split-Path -Parent $target
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($false)))
}

[CmdletBinding()]
param([string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))
$ErrorActionPreference = 'Stop'
$content = Join-Path $Root 'content'
$files = @(Get-ChildItem -LiteralPath $content -Recurse -Filter *.html -File)
$errors = New-Object System.Collections.Generic.List[string]
if ($files.Count -lt 16) { [void]$errors.Add("Expected at least 16 HTML pages, found $($files.Count)") }
foreach ($f in $files) {
  $s = [IO.File]::ReadAllText($f.FullName,[Text.Encoding]::UTF8)
  if ($s -notmatch '(?i)<style>') { [void]$errors.Add("No inline style: $($f.Name)") }
  if ($s -match '(?is)<script|<iframe|<form|<meta[^>]+http-equiv\s*=\s*["'']?refresh|@import|url\s*\(') { [void]$errors.Add("Forbidden active/remote construct: $($f.FullName)") }
  if ($s -match '(?i)\b(?:src|href)\s*=\s*["'']https?://') { [void]$errors.Add("Remote resource attribute: $($f.FullName)") }
  if ($s -match '(?i)(google-analytics|gtag\s*\(|pixel|doubleclick|facebook\.com/tr|<img)') { [void]$errors.Add("Tracking/ad construct: $($f.FullName)") }
  if ($s -match '(?i)(DeepSeek\s+(?:官方\s+)?Logo|官方安装器|官方 Agent|绝对安全)') { [void]$errors.Add("Brand/safety overclaim: $($f.FullName)") }
  foreach ($href in [regex]::Matches($s, '(?i)href\s*=\s*["'']([^"'']+)["'']')) {
    $target = $href.Groups[1].Value
    if ($target -match '^(?:https?:|//|mailto:)') { [void]$errors.Add("External link: $($f.FullName) -> $target") }
    elseif ($target -notmatch '^#') {
      $resolved = Join-Path $f.DirectoryName ($target.Split('#')[0])
      if (-not (Test-Path -LiteralPath $resolved)) { [void]$errors.Add("Broken relative link: $($f.FullName) -> $target") }
    }
  }
}
[pscustomobject]@{ Passed = ($errors.Count -eq 0); Files = $files.Count; Errors = @($errors) }
if ($errors.Count -gt 0) { exit 1 }

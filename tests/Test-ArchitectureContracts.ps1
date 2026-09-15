[CmdletBinding()]
param([string]$Root)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Id,[string]$Status,[string]$Message) { $results.Add([pscustomobject]@{ Id=$Id; Status=$Status; Message=$Message }) }
function Require-Text([string]$Id,[string]$Path,[string]$Pattern) {
  if (-not (Test-Path -LiteralPath $Path)) { Add-Result $Id 'PENDING' "Missing production file: $Path"; return }
  $text = Get-Content -LiteralPath $Path -Raw
  if ($text -match $Pattern) { Add-Result $Id 'PASS' "Contract found in $Path" } else { Add-Result $Id 'FAIL' "Contract missing in $Path" }
}
$requiredDocs = @('docs/ARCHITECTURE.md','docs/SECURITY-BOUNDARIES.md','docs/modules/M01-governance-manifest.md','docs/modules/M02-upstream-supply-chain.md','docs/modules/M03-powershell-core.md','docs/modules/M04-environment-checker.md','docs/modules/M05-controlled-launcher.md','acceptance/ACCEPTANCE-MATRIX.md')
foreach ($doc in $requiredDocs) { if (Test-Path (Join-Path $Root $doc)) { Add-Result "DOC-$doc" 'PASS' 'Referenced architecture contract exists' } else { Add-Result "DOC-$doc" 'FAIL' 'Required architecture contract missing' } }
Require-Text 'CONTRACT-CORE-LOOPBACK' (Join-Path $Root 'lib/XQDSH.Common.psm1') '127\.0\.0\.1'
if (Test-Path (Join-Path $Root 'launcher/Start-XQDSH.ps1')) {
  $p = Get-Content (Join-Path $Root 'launcher/Start-XQDSH.ps1') -Raw
  if ($p -match '(?i)(Invoke-Expression|cmd\s*/c)') { Add-Result 'CONTRACT-RUN-NO-EVAL' 'FAIL' 'Unsafe command evaluation wrapper found' }
  else { Add-Result 'CONTRACT-RUN-NO-EVAL' 'PASS' 'No command evaluation wrapper found' }
}
$results
if (($results | Where-Object Status -eq 'FAIL').Count -gt 0) { exit 1 }

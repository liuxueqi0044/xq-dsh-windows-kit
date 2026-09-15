[CmdletBinding()]
param([string]$Root, [switch]$RequireComplete)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Id,[string]$Status,[string]$Message) { $results.Add([pscustomobject]@{ Id=$Id; Status=$Status; Message=$Message }) }
function Assert-True([string]$Id,[bool]$Condition,[string]$Pass,[string]$Fail) { Add-Result $Id ($(if($Condition){'PASS'}else{'FAIL'})) ($(if($Condition){$Pass}else{$Fail})) }
function Pending([string]$Id,[string]$Message) { Add-Result $Id 'PENDING' $Message }
function Get-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Copy-Object([object]$Value) { $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
$fx = Join-Path $PSScriptRoot 'fixtures'
$valid = Get-Json (Join-Path $fx 'manifest-valid.fake.json')
$negative = Get-Json (Join-Path $fx 'manifest-negative.json')

# Discover the eventual production interfaces without importing third-party modules.
$common = Join-Path $Root 'lib/XQDSH.Common.psm1'
if (Test-Path -LiteralPath $common) { Import-Module $common -Force }
else { Pending 'CORE-001' 'lib/XQDSH.Common.psm1 is not present yet' }
$manifestPath = Join-Path $Root 'manifest/product-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { foreach($id in @('GOV-001','GOV-003','GOV-004','GOV-005','GOV-006','GOV-007','GOV-010','GOV-011')) { Pending $id 'product manifest/validator is not present yet' } }
if (-not (Test-Path -LiteralPath $common)) { foreach($id in @('CORE-003','CORE-004','CORE-005','CORE-006','CORE-007','CORE-008','CORE-009','CORE-010','CORE-011','CORE-012')) { Pending $id 'common security module is not present yet' } }

# Pure fixture invariants remain executable now and protect against weakening test data.
Assert-True 'TST-002-fixture' ($negative.latest.upstream.version -eq 'latest' -and $negative.wrongPackage.upstream.packageName -ne '@deepseek-ai/dsh' -and $negative.wrongRegistry.upstream.registry -ne 'https://registry.npmjs.org/') 'Negative manifest variants are distinct' 'Negative manifest fixture is malformed'
Assert-True 'TST-003-fixture' ($negative.wrongIntegrity.upstream.integrity -ne $valid.upstream.integrity -and $negative.wrongSha.upstream.sha256 -ne $valid.upstream.sha256) 'Hash mismatch variants are distinct' 'Hash mismatch fixture is malformed'
Assert-True 'TST-004-fixture' ($negative.wrongHost.runtime.webHost -ne '127.0.0.1' -and $negative.dangerousPermission.runtime.approval -eq 'never') 'Host and permission blockers are represented' 'Host/permission fixture is malformed'
Assert-True 'TST-005-fixture' ((Get-Json (Join-Path $fx 'workspace-paths.json')).root -eq 'C:\') 'Wide path fixture is present' 'Wide path fixture is malformed'
Assert-True 'TST-008-fixture' ((Get-Content (Join-Path $fx 'sensitive-canaries.txt') -Raw) -match 'FAKE_TEST') 'Sensitive canaries are visibly fake' 'Sensitive fixture lacks fake marker'
Assert-True 'TST-009-fixture' ((Get-Json (Join-Path $fx 'port-occupied.json')).action -eq 'report-only') 'Occupied-port fixture is non-destructive' 'Occupied-port fixture could imply process mutation'
Assert-True 'TST-013-fixture' ($negative.commandInjection.workspacePath -match ';' -and $negative.commandInjection.package -match 'INJECTED') 'Command-injection strings are represented' 'Injection fixture is malformed'

# Invoke available production functions with complete negative manifests; absent functions are PENDING.
function Try-Rejection([string]$Id,[string]$Function,$Value,[string]$ExpectedField = '') {
  if (-not (Test-Path -LiteralPath $common)) { Pending $Id "Common module is not present; $Function remains pending"; return }
  $cmd = Get-Command $Function -ErrorAction SilentlyContinue
  if (-not $cmd) { Pending $Id "Production function $Function is not present yet"; return }
  try { $r = & $Function $Value; $invalid = @($r.Evidence.InvalidFields); $fieldMatch = ([string]::IsNullOrWhiteSpace($ExpectedField) -or ($invalid -contains $ExpectedField)); $passed = ($null -ne $r -and $fieldMatch -and (($r -eq $false) -or ($r.Passed -eq $false) -or ($r.Status -in @('FAIL','BLOCKER','UNKNOWN')))); Assert-True $Id $passed 'Invalid input was rejected with expected field evidence' 'Invalid input or evidence was not rejected as expected' }
  catch { Add-Result $Id 'FAIL' ('Public function threw ' + $_.Exception.GetType().Name + ' instead of returning a structured rejection') }
}
function New-NegativeManifest([string]$Kind) {
  $m = Copy-Object $valid
  switch ($Kind) {
    'latest' { $m.upstream.version = 'latest' }
    'package' { $m.upstream.packageName = 'evil/dsh' }
    'registry' { $m.upstream.registry = 'https://registry.example.invalid/' }
    'host' { $m.runtime.webHost = '0.0.0.0' }
    'permission' { $m.runtime.sandbox = 'danger-full-access'; $m.runtime.approval = 'never' }
  }
  return $m
}
foreach ($case in @(
  @{ Id='GOV-003'; Kind='latest' },
  @{ Id='GOV-004'; Kind='package' },
  @{ Id='GOV-005'; Kind='registry' },
  @{ Id='GOV-006'; Kind='host' },
  @{ Id='GOV-007'; Kind='permission' }
)) { Try-Rejection $case.Id 'Test-XQManifestRuntimePolicy' (New-NegativeManifest $case.Kind) $case.Kind.Replace('latest','version').Replace('package','package').Replace('permission','defaultApproval') }
Try-Rejection 'CORE-007' 'Test-XQLoopbackHost' '0.0.0.0'
Try-Rejection 'CORE-004' 'Test-XQSafeWorkspace' 'C:\'

# M04/M05 entry points are intentionally checked as pending until their contracts exist.
foreach ($candidate in @('launcher/Test-XQDSHEnvironment.ps1','launcher/Start-XQDSH.ps1')) {
  $entryId = if($candidate -like '*Environment*'){'ENV-001'}else{'RUN-001'}
  if (-not (Test-Path (Join-Path $Root $candidate))) { Pending $entryId "Production entry point $candidate is not present yet" }
  elseif ($entryId -eq 'ENV-001') { Add-Result $entryId 'PASS' 'Environment entry point exists; read-only JSON contract is covered by the entry script' }
  else { Add-Result $entryId 'PASS' 'Launcher entry point exists; WhatIf contract is exercised by M05 harness' }
}

# Include the dedicated M05 harness results without allowing it to start a real process.
$m05 = Join-Path $PSScriptRoot 'M05-Launcher.Tests.ps1'
if (Test-Path -LiteralPath $m05) {
  try { foreach ($item in @(& $m05 -Root $Root -AsLibrary -RequireComplete:$RequireComplete)) { if ($item -is [psobject] -and $item.PSObject.Properties['Id']) { [void]$results.Add($item) } } }
  catch { [void]$results.Add([pscustomobject]@{ Id='RUN-M05-HARNESS'; Status='FAIL'; Message=('M05 harness threw ' + $_.Exception.GetType().Name) }) }
}

$results
$blocking = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0
if ($RequireComplete -and (@($results | Where-Object { $_.Status -eq 'PENDING' }).Count -gt 0)) { $blocking = $true }
if ($blocking) {
  foreach ($failure in @($results | Where-Object { $_.Status -eq 'FAIL' })) { Write-Host ('FAIL {0}: {1}' -f $failure.Id,$failure.Message) }
  if ($RequireComplete) { foreach ($pending in @($results | Where-Object { $_.Status -eq 'PENDING' })) { Write-Host ('PENDING {0}: {1}' -f $pending.Id,$pending.Message) } }
  exit 1
}

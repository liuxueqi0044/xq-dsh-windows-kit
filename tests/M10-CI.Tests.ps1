$root = Split-Path $PSScriptRoot -Parent
function Assert-XQ { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

Describe 'M10 test orchestration and CI contracts' {
  It 'TST-001 maps every M10 acceptance case to a test' {
    $matrix = Get-Content (Join-Path $PSScriptRoot 'm10-test-matrix.json') -Raw | ConvertFrom-Json
    foreach ($id in 1..16) { $key = 'TST-{0:D3}' -f $id; Assert-XQ ($null -ne $matrix.cases.$key -and @($matrix.cases.$key).Count -gt 0) "$key has no mapping" }
  }
  It 'TST-013 has a single PowerShell 5.1/7-compatible orchestrator' {
    $s = Get-Content (Join-Path $PSScriptRoot 'Invoke-Tests.ps1') -Raw
    Assert-XQ ($s -match "ValidateSet\('Validate','Candidate'\)") 'Mode contract missing'
    Assert-XQ ($s -match 'NoProfile') 'NoProfile isolation missing'
    Assert-XQ ($s -match 'SkippedCount' -and $s -match 'PendingCount') 'Skipped/pending are not blocking'
  }
  It 'TST-014 never treats skipped, pending, inconclusive, or missing summaries as success' {
    $s = Get-Content (Join-Path $PSScriptRoot 'Invoke-Tests.ps1') -Raw
    Assert-XQ ($s -match 'Where-Object \{ \$_.status -ne ''PASS'' \}' -and $s -match 'if \(\$failures.Count -gt 0\) \{ exit 1 \}') 'Non-pass result handling missing'
    Assert-XQ ($s -match 'SummaryPath' -and $s -match 'Set-Content') 'Summary output contract missing'
  }
  It 'validate workflow is push/PR main only and does not invoke candidate build or resolver' {
    $s = Get-Content (Join-Path $root '.github/workflows/validate.yml') -Raw
    Assert-XQ ($s -match 'pull_request:' -and $s -match 'branches: \[main\]') 'Main PR trigger missing'
    Assert-XQ ($s -notmatch 'Resolve-OfficialPackage|Build-Package|Mode Candidate') 'Validate invokes candidate work'
    Assert-XQ ($s -match 'RequiredVersion 3\.4\.0' -and $s -match 'jsonschema==4\.25\.1' -and $s -match 'no-cache-dir') 'Pinned test dependencies or cache policy missing'
    Assert-XQ ($s -match 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' -and $s -match 'actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97' -and $s -match 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a') 'Official actions are not pinned to reviewed commits'
  }
  It 'candidate workflow is manual, explicit, and invokes complete gates' {
    $s = Get-Content (Join-Path $root '.github/workflows/build-candidate.yml') -Raw
    Assert-XQ ($s -match 'workflow_dispatch:' -and $s -notmatch '(?m)^\s+push:') 'Candidate is not manual-only'
    Assert-XQ ($s -match 'BUILD-CANDIDATE' -and $s -match 'Mode Candidate') 'Explicit candidate authorization/gates missing'
    Assert-XQ ($s -match 'RequiredVersion 3\.4\.0' -and $s -match 'if-no-files-found: error' -and $s -match 'dist/\*\*') 'Pinned dependency or evidence requirement missing'
  }
}

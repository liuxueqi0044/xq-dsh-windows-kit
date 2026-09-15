$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $root 'acceptance\Test-ReleaseEvidence.ps1'

function Read-XQJson { param([string]$Path) [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json }
function Write-XQJson { param([string]$Path,[object]$Value) [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false))) }
function New-XQAcceptanceFixture {
    param([string]$Name)
    $destination = Join-Path $TestDrive $Name
    Copy-Item -LiteralPath (Join-Path $root 'acceptance') -Destination $destination -Recurse
    return $destination
}
function Invoke-XQEvidenceValidator { param([string]$AcceptanceRoot) ((& $validator -AcceptanceRoot $AcceptanceRoot -NoExit | Out-String) | ConvertFrom-Json) }

Describe 'M11 release evidence gate' {
    It 'accepts the honest PENDING templates as structurally valid but incomplete' {
        $result = Invoke-XQEvidenceValidator (Join-Path $root 'acceptance')
        $result.Valid | Should Be $true
        $result.Complete | Should Be $false
    }

    It 'REL-002 rejects incomplete evidence with exit code 2 when completion is required' {
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -AcceptanceRoot (Join-Path $root 'acceptance') -RequireComplete
        $LASTEXITCODE | Should Be 2
    }

    It 'rejects a suite that claims PASS while an item remains PENDING and reviewers are identical' {
        $fixture = New-XQAcceptanceFixture 'suite-conflict'
        $path = Join-Path $fixture 'vm-zh\evidence.json'
        $evidence = Read-XQJson $path
        $evidence.status='PASS';$evidence.environment.vmId='zh-test';$evidence.environment.osCaption='Windows 11';$evidence.environment.osBuild='26100';$evidence.environment.snapshotId='clean-1';$evidence.environment.isolated=$true
        $evidence.product.candidateZipSha256=('a'*64);$evidence.startedAtUtc='2026-08-29T00:00:00Z';$evidence.endedAtUtc='2026-08-29T01:00:00Z';$evidence.executor='same-person';$evidence.reviewer='same-person';$evidence.privacyAttestation=$true
        Write-XQJson $path $evidence
        $result = Invoke-XQEvidenceValidator $fixture
        @($result.Issues.Code) -contains 'SUITE_PASS_ITEMS_NOT_PASS' | Should Be $true
        @($result.Issues.Code) -contains 'VM_PASS_ATTESTATION_INVALID' | Should Be $true
    }

    It 'rejects recognized secret text in a pending evidence record' {
        $fixture = New-XQAcceptanceFixture 'secret'
        $path = Join-Path $fixture 'vm-en\evidence.json'
        $evidence = Read-XQJson $path
        $evidence.items[0].notes = 'token=FAKE_TEST_SECRET_DO_NOT_USE'
        Write-XQJson $path $evidence
        $result = Invoke-XQEvidenceValidator $fixture
        @($result.Issues.Code) -contains 'EVIDENCE_SECRET' | Should Be $true
    }

    It 'rejects an evidence file whose approved SHA-256 does not match' {
        $fixture = New-XQAcceptanceFixture 'hash-mismatch'
        $suite = Join-Path $fixture 'vm-en'
        [IO.File]::WriteAllText((Join-Path $suite 'evidence.txt'),'safe test evidence',(New-Object Text.UTF8Encoding($false)))
        $path = Join-Path $suite 'evidence.json'
        $evidence = Read-XQJson $path
        $evidence.status='FAIL';$evidence.items[0].status='FAIL';$evidence.items[0].command='Write-Output test';$evidence.items[0].actual='Expected failure';$evidence.items[0].evidenceFiles=@('evidence.txt');$evidence.items[0].evidenceHashes=@('0'*64)
        Write-XQJson $path $evidence
        $result = Invoke-XQEvidenceValidator $fixture
        @($result.Issues.Code) -contains 'EVIDENCE_HASH_MISMATCH' | Should Be $true
    }

    It 'does not modify the product manifest' {
        $manifest = Join-Path $root 'manifest\product-manifest.json'
        $before = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
        $null = & $validator -AcceptanceRoot (Join-Path $root 'acceptance') -NoExit
        (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash | Should Be $before
    }
}

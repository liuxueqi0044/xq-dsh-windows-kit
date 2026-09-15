[CmdletBinding()]
param(
    [string]$AcceptanceRoot,
    [string]$ReleaseManifestPath,
    [switch]$RequireComplete,
    [switch]$NoExit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($AcceptanceRoot)) { $AcceptanceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$AcceptanceRoot = [IO.Path]::GetFullPath($AcceptanceRoot).TrimEnd('\','/')
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $AcceptanceRoot)).TrimEnd('\','/')
if ([string]::IsNullOrWhiteSpace($ReleaseManifestPath)) { $ReleaseManifestPath = Join-Path $repositoryRoot 'dist\release-manifest.json' }
$ReleaseManifestPath = [IO.Path]::GetFullPath($ReleaseManifestPath)

$issues = New-Object System.Collections.Generic.List[object]
$requiredIds = @(1..14 | ForEach-Object {'VM-{0:D3}' -f $_})
$gateNames = @('automatedM01M10','githubMainValidate','upstreamObservation','vmZh','vmEn')

function Add-XQEvidenceIssue {
    param([string]$Code,[string]$Context)
    [void]$issues.Add([pscustomobject][ordered]@{Code=$Code;Context=$Context})
}

function Get-XQPropertyValue {
    param([object]$Object,[string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-XQSecretText {
    param([string]$Text,[string]$Context)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $patterns = @(
        '(?i)authorization\s*:\s*bearer\s+(?!\[REDACTED(?::BEARER)?\])\S+',
        '\bsk-[A-Za-z0-9_-]{8,}\b',
        '\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b',
        '(?i)\b(?:password|token|secret|cookie|api[_-]?key)\b\s*[:=]\s*(?!\[REDACTED(?::[A-Z_]+)?\])[^\s,;]+'
    )
    foreach ($pattern in $patterns) { if ([regex]::IsMatch($Text,$pattern)) { Add-XQEvidenceIssue 'EVIDENCE_SECRET' $Context; return } }
}

function Read-XQEvidenceJson {
    param([string]$Path,[string]$Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Add-XQEvidenceIssue 'JSON_MISSING' $Context; return $null }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Length -gt 5242880) { Add-XQEvidenceIssue 'JSON_TOO_LARGE' $Context; return $null }
        $raw = [IO.File]::ReadAllText($item.FullName,[Text.Encoding]::UTF8)
        Test-XQSecretText $raw $Context
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { Add-XQEvidenceIssue 'JSON_INVALID' $Context; return $null }
}

function Test-XQPathUnderRoot {
    param([string]$Root,[string]$Candidate)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full = [IO.Path]::GetFullPath($Candidate)
    return $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}

function Test-XQRelativeEvidencePath {
    param([string]$Base,[string]$Relative,[string]$Context)
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { Add-XQEvidenceIssue 'EVIDENCE_FILE_INVALID' $Context; return $null }
    try { $full = [IO.Path]::GetFullPath((Join-Path $Base ($Relative -replace '/','\'))) } catch { Add-XQEvidenceIssue 'EVIDENCE_FILE_INVALID' $Context; return $null }
    if (-not (Test-XQPathUnderRoot $Base $full) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { Add-XQEvidenceIssue 'EVIDENCE_FILE_INVALID' $Context; return $null }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 26214400) { Add-XQEvidenceIssue 'EVIDENCE_FILE_REFUSED' $Context; return $null }
    return $item.FullName
}

function Test-XQDateOrder {
    param([object]$Started,[object]$Ended,[string]$Context)
    if ($null -eq $Started -and $null -eq $Ended) { return }
    try {
        $startDate = [DateTimeOffset]::Parse([string]$Started)
        $endDate = [DateTimeOffset]::Parse([string]$Ended)
        if ($startDate -gt $endDate) { Add-XQEvidenceIssue 'VM_TIME_INVALID' $Context }
    } catch { Add-XQEvidenceIssue 'VM_TIME_INVALID' $Context }
}

function Test-XQVmEvidence {
    param([string]$SuiteId,[string]$Locale)
    $path = Join-Path $AcceptanceRoot ($SuiteId + '\evidence.json')
    $evidence = Read-XQEvidenceJson $path $SuiteId
    if ($null -eq $evidence) { return $null }
    $suiteDirectory = Split-Path -Parent $path

    if ($evidence.suiteId -cne $SuiteId -or $evidence.environment.locale -cne $Locale -or $evidence.environment.architecture -cne 'x64' -or $evidence.product.productVersion -cne '1.0.0' -or $evidence.product.dshVersion -cne '0.1.1-rc.2') { Add-XQEvidenceIssue 'VM_IDENTITY_INVALID' $SuiteId }
    $items = @(Get-XQPropertyValue $evidence 'items')
    $ids = @($items | ForEach-Object {Get-XQPropertyValue $_ 'id'})
    $uniqueIds = @($ids | Sort-Object -Unique)
    if ($items.Count -ne 14 -or $uniqueIds.Count -ne 14 -or @($requiredIds | Where-Object {$uniqueIds -notcontains $_}).Count -ne 0) { Add-XQEvidenceIssue 'VM_ITEMS_INVALID' $SuiteId }

    foreach ($item in $items) {
        $id = [string](Get-XQPropertyValue $item 'id')
        $status = [string](Get-XQPropertyValue $item 'status')
        if ($requiredIds -notcontains $id -or @('PASS','FAIL','PENDING') -notcontains $status) { Add-XQEvidenceIssue 'VM_ITEM_INVALID' ($SuiteId + ':' + $id); continue }
        $actual = Get-XQPropertyValue $item 'actual'
        $command = Get-XQPropertyValue $item 'command'
        $hashes = @(Get-XQPropertyValue $item 'evidenceHashes')
        $files = @(Get-XQPropertyValue $item 'evidenceFiles')
        if ($status -in @('PASS','FAIL')) {
            if ([string]::IsNullOrWhiteSpace([string]$actual) -or [string]::IsNullOrWhiteSpace([string]$command) -or $hashes.Count -eq 0 -or $files.Count -eq 0 -or $hashes.Count -ne $files.Count) { Add-XQEvidenceIssue 'ITEM_EVIDENCE_INCOMPLETE' ($SuiteId + ':' + $id) }
            $seenFiles = @{}
            for ($index=0; $index -lt [Math]::Min($hashes.Count,$files.Count); $index++) {
                $expectedHash = [string]$hashes[$index]
                $relativeFile = [string]$files[$index]
                if ($expectedHash -notmatch '^[a-f0-9]{64}$' -or $seenFiles.ContainsKey($relativeFile.ToLowerInvariant())) { Add-XQEvidenceIssue 'EVIDENCE_HASH_OR_MAPPING_INVALID' ($SuiteId + ':' + $id); continue }
                $seenFiles[$relativeFile.ToLowerInvariant()] = $true
                $fullPath = Test-XQRelativeEvidencePath $suiteDirectory $relativeFile ($SuiteId + ':' + $id)
                if ($null -eq $fullPath) { continue }
                $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actualHash -cne $expectedHash) { Add-XQEvidenceIssue 'EVIDENCE_HASH_MISMATCH' ($SuiteId + ':' + $id) }
                $bytes = [IO.File]::ReadAllBytes($fullPath)
                Test-XQSecretText ([Text.Encoding]::UTF8.GetString($bytes)) ($SuiteId + ':' + $id)
            }
        }
    }

    $statuses = @($items | ForEach-Object {[string](Get-XQPropertyValue $_ 'status')})
    if ($evidence.status -eq 'PASS' -and @($statuses | Where-Object {$_ -ne 'PASS'}).Count -ne 0) { Add-XQEvidenceIssue 'SUITE_PASS_ITEMS_NOT_PASS' $SuiteId }
    elseif ($evidence.status -eq 'FAIL' -and @($statuses | Where-Object {$_ -eq 'FAIL'}).Count -eq 0) { Add-XQEvidenceIssue 'SUITE_FAIL_CONFLICT' $SuiteId }
    elseif ($evidence.status -eq 'PENDING' -and (@($statuses | Where-Object {$_ -eq 'FAIL'}).Count -ne 0 -or @($statuses | Where-Object {$_ -eq 'PENDING'}).Count -eq 0)) { Add-XQEvidenceIssue 'SUITE_PENDING_CONFLICT' $SuiteId }

    Test-XQDateOrder (Get-XQPropertyValue $evidence 'startedAtUtc') (Get-XQPropertyValue $evidence 'endedAtUtc') $SuiteId
    if ($evidence.status -eq 'PASS') {
        $environmentValues = @($evidence.environment.vmId,$evidence.environment.osCaption,$evidence.environment.osBuild,$evidence.environment.snapshotId)
        $placeholders = @($environmentValues | Where-Object {[string]::IsNullOrWhiteSpace([string]$_) -or $_ -eq 'PENDING'})
        if (-not $evidence.environment.isolated -or -not $evidence.privacyAttestation -or [string]::IsNullOrWhiteSpace([string]$evidence.executor) -or [string]::IsNullOrWhiteSpace([string]$evidence.reviewer) -or $evidence.executor -ceq $evidence.reviewer -or $null -eq $evidence.startedAtUtc -or $null -eq $evidence.endedAtUtc -or [string]$evidence.product.candidateZipSha256 -notmatch '^[a-f0-9]{64}$' -or $placeholders.Count -ne 0) { Add-XQEvidenceIssue 'VM_PASS_ATTESTATION_INVALID' $SuiteId }
    }
    return $evidence
}

$vmZh = Test-XQVmEvidence 'vm-zh' 'zh-CN'
$vmEn = Test-XQVmEvidence 'vm-en' 'en-US'
$decisionPath = Join-Path $AcceptanceRoot 'release-decision.json'
$decision = Read-XQEvidenceJson $decisionPath 'release-decision'

if ($null -ne $decision) {
    foreach ($gateName in $gateNames) {
        $gate = Get-XQPropertyValue $decision $gateName
        $gateStatus = [string](Get-XQPropertyValue $gate 'status')
        if ($null -eq $gate -or @('PASS','FAIL','PENDING') -notcontains $gateStatus) { Add-XQEvidenceIssue 'RELEASE_GATE_INVALID' $gateName }
    }
    $gateStatuses = @($gateNames | ForEach-Object {[string](Get-XQPropertyValue (Get-XQPropertyValue $decision $_) 'status')})
    if ($decision.status -eq 'PASS' -and @($gateStatuses | Where-Object {$_ -ne 'PASS'}).Count -ne 0) { Add-XQEvidenceIssue 'RELEASE_STATUS_CONFLICT' 'release-decision' }
    elseif ($decision.status -eq 'FAIL' -and @($gateStatuses | Where-Object {$_ -eq 'FAIL'}).Count -eq 0) { Add-XQEvidenceIssue 'RELEASE_STATUS_CONFLICT' 'release-decision' }
    elseif ($decision.status -eq 'PENDING' -and (@($gateStatuses | Where-Object {$_ -eq 'FAIL'}).Count -ne 0 -or @($gateStatuses | Where-Object {$_ -eq 'PENDING'}).Count -eq 0)) { Add-XQEvidenceIssue 'RELEASE_STATUS_CONFLICT' 'release-decision' }

    if ($decision.status -eq 'PASS') {
        if ([string]$decision.candidateZipSha256 -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace([string]$decision.executor) -or [string]::IsNullOrWhiteSpace([string]$decision.reviewer) -or $decision.executor -ceq $decision.reviewer -or $null -eq $decision.decidedAtUtc) { Add-XQEvidenceIssue 'RELEASE_PASS_ATTESTATION_INVALID' 'release-decision' }
        foreach ($gateName in $gateNames) { if ([string]::IsNullOrWhiteSpace([string](Get-XQPropertyValue (Get-XQPropertyValue $decision $gateName) 'reference'))) { Add-XQEvidenceIssue 'RELEASE_GATE_REFERENCE_MISSING' $gateName } }
        if ($null -eq $vmZh -or $null -eq $vmEn -or $vmZh.status -ne 'PASS' -or $vmEn.status -ne 'PASS' -or $vmZh.product.candidateZipSha256 -cne $decision.candidateZipSha256 -or $vmEn.product.candidateZipSha256 -cne $decision.candidateZipSha256) { Add-XQEvidenceIssue 'CANDIDATE_HASH_OR_VM_MISMATCH' 'release-decision' }

        $mainReference = [string](Get-XQPropertyValue (Get-XQPropertyValue $decision 'githubMainValidate') 'reference')
        if ($mainReference -notmatch '^https://github\.com/liuxueqi0044/xq-dsh-windows-kit/actions/runs/[0-9]+(?:/job/[0-9]+)?$') { Add-XQEvidenceIssue 'GITHUB_MAIN_REFERENCE_INVALID' 'githubMainValidate' }

        foreach ($localGateName in @('automatedM01M10','upstreamObservation')) {
            $reference = [string](Get-XQPropertyValue (Get-XQPropertyValue $decision $localGateName) 'reference')
            $localPath = Test-XQRelativeEvidencePath $repositoryRoot $reference $localGateName
            if ($null -ne $localPath) {
                $localJson = Read-XQEvidenceJson $localPath $localGateName
                if ($null -eq $localJson -or [string](Get-XQPropertyValue $localJson 'status') -ne 'PASS') { Add-XQEvidenceIssue 'LOCAL_GATE_REFERENCE_INVALID' $localGateName }
            }
        }

        $vmZhReference = [string](Get-XQPropertyValue (Get-XQPropertyValue $decision 'vmZh') 'reference')
        $vmEnReference = [string](Get-XQPropertyValue (Get-XQPropertyValue $decision 'vmEn') 'reference')
        if ($vmZhReference.Replace('\','/') -ne 'acceptance/vm-zh/evidence.json' -or $vmEnReference.Replace('\','/') -ne 'acceptance/vm-en/evidence.json') { Add-XQEvidenceIssue 'VM_GATE_REFERENCE_INVALID' 'release-decision' }

        $releaseManifest = Read-XQEvidenceJson $ReleaseManifestPath 'release-manifest'
        if ($null -eq $releaseManifest -or $releaseManifest.buildKind -ne 'candidate' -or $releaseManifest.zipSha256 -cne $decision.candidateZipSha256) { Add-XQEvidenceIssue 'RELEASE_MANIFEST_HASH_MISMATCH' 'release-manifest' }
        else {
            $zipRelative = [string]$releaseManifest.zipFile
            $zipPath = Test-XQRelativeEvidencePath (Split-Path -Parent $ReleaseManifestPath) $zipRelative 'candidate-zip'
            if ($null -ne $zipPath -and (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $decision.candidateZipSha256) { Add-XQEvidenceIssue 'CANDIDATE_ZIP_HASH_MISMATCH' 'candidate-zip' }
        }
    }
}

$issueArray = @($issues | ForEach-Object { $_ })
$complete = ($issueArray.Count -eq 0 -and $null -ne $decision -and $decision.status -eq 'PASS' -and $null -ne $vmZh -and $vmZh.status -eq 'PASS' -and $null -ne $vmEn -and $vmEn.status -eq 'PASS')
if ($RequireComplete -and -not $complete) { Add-XQEvidenceIssue 'RELEASE_NOT_COMPLETE' 'release-decision'; $issueArray = @($issues | ForEach-Object { $_ }) }
$output = [pscustomobject][ordered]@{Valid=($issueArray.Count -eq 0);Complete=$complete;RecommendedStatus=$(if($complete){'releasable'}else{'draft-or-candidate'});Issues=$issueArray}
$output | ConvertTo-Json -Depth 6
if (-not $NoExit) {
    if ($issueArray.Count -gt 0) { exit $(if($RequireComplete){2}else{3}) }
    exit 0
}

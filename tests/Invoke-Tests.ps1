[CmdletBinding()]
param(
    [ValidateSet('Validate','Candidate')][string]$Mode = 'Validate',
    [string]$Root,
    [string]$SummaryPath
)

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$Root = [IO.Path]::GetFullPath($Root)
if ([string]::IsNullOrWhiteSpace($SummaryPath)) { $SummaryPath = Join-Path $Root ("tests\results\{0}-summary.json" -f $Mode.ToLowerInvariant()) }
$SummaryPath = [IO.Path]::GetFullPath($SummaryPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow
$items = New-Object System.Collections.Generic.List[object]

function Add-XQTestItem {
    param([string]$Name,[string]$Status,[string]$Message,[int]$ExitCode=0)
    [void]$items.Add([pscustomobject][ordered]@{name=$Name;status=$Status;message=$Message;exitCode=$ExitCode})
    Write-Verbose ("{0}: {1} ({2})" -f $Name,$Status,$Message)
}

function Get-XQTestItems { return @($items | ForEach-Object { $_ }) }

function Get-XQPythonExecutable {
    foreach ($command in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        if ($command.CommandType -ne 'Application' -or -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) { continue }
        try {
            # Windows may expose non-runnable Store aliases as python.exe.  Probe the
            # exact executable and the pinned validator dependency before selecting it.
            $probe = @(& ([string]$command.Source) -c 'import jsonschema,sys;sys.stdout.write(str(sys.version_info[0]))' 2>$null)
            if ($LASTEXITCODE -eq 0 -and (($probe -join '').Trim() -eq '3')) { return [string]$command.Source }
        } catch {}
    }
    return $null
}

function Invoke-XQExternalTest {
    param([string]$Name,[string]$File,[string[]]$Arguments=@())
    $path = Join-Path $Root $File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-XQTestItem $Name 'FAIL' "Required file missing: $File" 5; return }
    if (-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) { Add-XQTestItem $Name 'FAIL' 'Windows PowerShell 5.1 is required.' 5; return }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) { Add-XQTestItem $Name 'FAIL' "Process returned exit code $code." $code }
    else { Add-XQTestItem $Name 'PASS' 'Completed.' }
}

function Invoke-XQPesterFile {
    param([string]$Name,[string]$File)
    $path = Join-Path $Root $File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-XQTestItem $Name 'FAIL' "Required Pester file missing: $File" 5; return }
    $helper = Join-Path $Root 'tests\Invoke-PesterFile.ps1'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { Add-XQTestItem $Name 'FAIL' 'Isolated Pester helper is missing.' 5; return }
    $resultPath = Join-Path ([IO.Path]::GetTempPath()) ('xq-pester-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        # Pester 3 retains Mock/TestDrive state between Invoke-Pester calls.  Run each
        # file in a clean Windows PowerShell process so suites cannot pollute one another.
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -TestPath $path -ResultPath $resultPath
        $helperCode = $LASTEXITCODE
        if ($helperCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            Add-XQTestItem $Name 'FAIL' "Isolated Pester process returned exit code $helperCode." $helperCode
            return
        }
        $result = [IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) { [IO.File]::Delete($resultPath) }
    }
    $failedProperty = $result.PSObject.Properties['FailedCount']; $failed = if($null -eq $failedProperty){0}else{[int]$failedProperty.Value}
    $skippedProperty = $result.PSObject.Properties['SkippedCount']; $skipped = if($null -eq $skippedProperty){0}else{[int]$skippedProperty.Value}
    $pendingProperty = $result.PSObject.Properties['PendingCount']; $pending = if($null -eq $pendingProperty){0}else{[int]$pendingProperty.Value}
    $inconclusiveProperty = $result.PSObject.Properties['InconclusiveCount']; $inconclusive = if($null -eq $inconclusiveProperty){0}else{[int]$inconclusiveProperty.Value}
    $passedProperty = $result.PSObject.Properties['PassedCount']; $passed = if($null -eq $passedProperty){0}else{[int]$passedProperty.Value}
    if (($failed + $skipped + $pending + $inconclusive) -gt 0) {
        $details = @($result.Failures | ForEach-Object { '{0}: {1}' -f $_.Name,(($_.Message -replace '[\r\n]+',' ').Trim()) }) -join ' | '
        Add-XQTestItem $Name 'FAIL' ("failed={0}; skipped={1}; pending={2}; inconclusive={3}; {4}" -f $failed,$skipped,$pending,$inconclusive,$details) 1
    } elseif ($passed -lt 1) {
        Add-XQTestItem $Name 'FAIL' 'No passing tests were discovered.' 1
    } else {
        Add-XQTestItem $Name 'PASS' ("passed={0}" -f $passed)
    }
}

function Invoke-XQRequiredTests {
    param([bool]$IncludeNetwork)
    Invoke-XQExternalTest 'M01-M05-harness' 'tests\Invoke-M01-M05Tests.ps1' @('-Root',$Root,'-RequireComplete')
    $pesterFiles = @(
        'tests\M01-Governance.Tests.ps1',
        'tests\M03-Common.Tests.ps1',
        'tests\M04-Environment.Tests.ps1',
        'tests\M06-Diagnostics.Tests.ps1',
        'tests\M07-OfflineContent.Tests.ps1',
        'tests\M08-Extensions.Tests.ps1',
        'tests\M09-Packaging.Tests.ps1',
        'tests\M10-CI.Tests.ps1'
    )
    if ($IncludeNetwork) { $pesterFiles = @('tests\M02-SupplyChain.Tests.ps1') + $pesterFiles }
    foreach ($file in $pesterFiles) { Invoke-XQPesterFile ([IO.Path]::GetFileNameWithoutExtension($file)) $file }

    $schemaValidator = Join-Path $Root 'tests\Validate-JsonSchemas.py'
    if (-not (Test-Path -LiteralPath $schemaValidator -PathType Leaf)) { Add-XQTestItem 'JSON-schema-validation' 'FAIL' 'Schema validator is missing.' 5 }
    else {
        # Pester 3 can leave the host in its ephemeral TestDrive.  Always restore a
        # stable working directory before spawning Python on Windows PowerShell 5.1.
        Push-Location -LiteralPath $Root
        try {
            $pythonExecutable = Get-XQPythonExecutable
            if ($null -eq $pythonExecutable) { Add-XQTestItem 'JSON-schema-validation' 'FAIL' 'Python 3 with the pinned jsonschema dependency is unavailable.' 5 }
            else {
                & $pythonExecutable $schemaValidator
                if ($LASTEXITCODE -ne 0) { Add-XQTestItem 'JSON-schema-validation' 'FAIL' "Python returned exit code $LASTEXITCODE." $LASTEXITCODE }
                else { Add-XQTestItem 'JSON-schema-validation' 'PASS' 'Completed.' }
            }
        } finally { Pop-Location }
    }
}

function Get-XQInputCommit {
    if ($env:GITHUB_SHA -match '^[0-9a-fA-F]{40}$') { return $env:GITHUB_SHA.ToLowerInvariant() }
    try {
        $value = (& git -C $Root rev-parse HEAD 2>$null).Trim().ToLowerInvariant()
        if ($LASTEXITCODE -eq 0 -and $value -match '^[0-9a-f]{40}$') { return $value }
    } catch {}
    return 'UNAVAILABLE'
}

function Write-XQNewJson {
    param([string]$Path,[object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][IO.Directory]::CreateDirectory($parent) }
    $text = $Value | ConvertTo-Json -Depth 20
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=$encoding.GetBytes($text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
}

Invoke-XQRequiredTests -IncludeNetwork:($Mode -eq 'Candidate')

if ($Mode -eq 'Candidate') {
    $resultsRoot = Split-Path -Parent $SummaryPath
    $gatePath = Join-Path $resultsRoot 'm10-prebuild-gate.json'
    $observationRoot = Join-Path $resultsRoot 'upstream-observation'
    $preBuildItems = Get-XQTestItems
    $preBuildFailures = @($preBuildItems | Where-Object {$_.status -ne 'PASS'})
    $inputCommit = Get-XQInputCommit

    if ($preBuildFailures.Count -gt 0) { Add-XQTestItem 'M10-prebuild-gate' 'FAIL' 'Required M01-M10 tests did not all pass.' 1 }
    elseif ($inputCommit -eq 'UNAVAILABLE') { Add-XQTestItem 'M10-prebuild-gate' 'FAIL' 'Candidate builds require an immutable 40-character input commit.' 1 }
    elseif ((Test-Path -LiteralPath $gatePath) -or (Test-Path -LiteralPath $observationRoot)) { Add-XQTestItem 'M10-prebuild-gate' 'FAIL' 'Candidate evidence target already exists; evidence is never mixed or overwritten.' 1 }
    else {
        [void][IO.Directory]::CreateDirectory($observationRoot)
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Root 'build\Resolve-OfficialPackage.ps1') -OutputDirectory $observationRoot
        $resolverCode = $LASTEXITCODE
        $observationPath = Join-Path $observationRoot 'source-observation.json'
        if ($resolverCode -ne 0 -or -not (Test-Path -LiteralPath $observationPath -PathType Leaf)) {
            Add-XQTestItem 'source-observation' 'FAIL' 'Online official-source observation failed.' $resolverCode
        } else {
            $observation = [IO.File]::ReadAllText($observationPath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ($observation.status -ne 'PASS') { Add-XQTestItem 'source-observation' 'FAIL' 'source-observation.status is not PASS.' 2 }
            else {
                Add-XQTestItem 'source-observation' 'PASS' 'Official source observation passed.'
                $manifestPath = Join-Path $Root 'manifest\product-manifest.json'
                $relativeObservationPath = $observationPath.Substring($Root.Length).TrimStart('\','/').Replace('\','/')
                $gate = [ordered]@{
                    schema = 'xq.m10.prebuild-gate.v1'
                    scope = 'M10-PREBUILD'
                    status = 'PASS'
                    manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    sourceObservationPath = $relativeObservationPath
                    sourceObservationSha256 = (Get-FileHash -LiteralPath $observationPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    results = $preBuildItems
                    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
                    commit = $inputCommit
                }
                Write-XQNewJson -Path $gatePath -Value $gate
                Add-XQTestItem 'M10-prebuild-gate' 'PASS' 'All required tests and source observation passed.'
            }
        }
    }

    if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
        $buildPath = Join-Path $Root 'build\Build-Package.ps1'
        $distPath = Join-Path $Root 'dist'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $buildPath -Root $Root -Candidate -PreBuildGatePath $gatePath -OutputRoot $distPath
        $buildCode = $LASTEXITCODE
        $zipPath = Join-Path $distPath 'XQ-DSH-Windows-v1.0.0.zip'
        $directoryPath = Join-Path $distPath 'XQ-DSH-Windows-v1.0.0'
        $releasePath = Join-Path $distPath 'release-manifest.json'
        if ($buildCode -ne 0 -or -not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or -not (Test-Path -LiteralPath $directoryPath -PathType Container) -or -not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
            Add-XQTestItem 'M09-candidate-artifact' 'FAIL' 'Candidate directory, ZIP, or release manifest is missing, or the build failed.' $buildCode
        } else {
            $release = [IO.File]::ReadAllText($releasePath,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            $actualZipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($release.buildKind -ne 'candidate' -or $release.productReleaseState -ne 'draft' -or $release.zipSha256 -cne $actualZipHash) { Add-XQTestItem 'M09-candidate-artifact' 'FAIL' 'Candidate artifact metadata does not match its ZIP.' 2 }
            else { Add-XQTestItem 'M09-candidate-artifact' 'PASS' 'Candidate directory, ZIP, and release manifest agree.' }
        }
    }
}

$allItems = Get-XQTestItems
$failures = @($allItems | Where-Object { $_.status -ne 'PASS' })
$summary = [ordered]@{
    schema = 'xq.m10.test-summary.v1'
    mode = $Mode.ToLowerInvariant()
    startedUtc = $started.ToString('o')
    completedUtc = [DateTime]::UtcNow.ToString('o')
    results = $allItems
    passed = @($allItems | Where-Object {$_.status -eq 'PASS'}).Count
    failures = $failures.Count
    status = $(if($failures.Count -eq 0){'PASS'}else{'FAIL'})
}

$summaryParent = Split-Path -Parent $SummaryPath
if (-not (Test-Path -LiteralPath $summaryParent -PathType Container)) { [void][IO.Directory]::CreateDirectory($summaryParent) }
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
[pscustomobject]$summary
if ($failures.Count -gt 0) { exit 1 }

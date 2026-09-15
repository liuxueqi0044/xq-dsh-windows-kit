$scriptPath = Join-Path $PSScriptRoot '..\launcher\Test-XQDSHEnvironment.ps1'
$manifestPath = Join-Path $PSScriptRoot '..\manifest\product-manifest.json'
function Assert-XQ { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

Describe 'M04 read-only environment checker' {
    It 'emits structured JSON and does not require a workspace to exist' {
        $candidate = Join-Path $TestDrive 'not-created'
        $output = & $scriptPath -WorkspacePath $candidate -ManifestPath $manifestPath -OutputFormat Json
        $report = $output | ConvertFrom-Json
        Assert-XQ ($report.Tool -eq 'Test-XQDSHEnvironment') 'unexpected report tool'
        Assert-XQ (@($report.Results).Count -gt 1) 'expected multiple checks'
        Assert-XQ (-not (Test-Path -LiteralPath $candidate)) 'checker created workspace'
        Assert-XQ (@($report.Results | Where-Object { $_.PSObject.Properties.Name -notcontains 'Evidence' }).Count -eq 0) 'JSON result shape is unstable'
    }
    It 'returns a structured manifest result for a missing manifest' {
        $output = & $scriptPath -ManifestPath (Join-Path $TestDrive 'missing.json') -OutputFormat Json
        $report = $output | ConvertFrom-Json
        Assert-XQ (@($report.Results | Where-Object Code -eq 'MANIFEST_NOT_FOUND').Count -eq 1) 'missing manifest was not structured'
    }
    It 'uses its default manifest path under Windows PowerShell 5.1' {
        $candidate = Join-Path $TestDrive 'ps51-not-created'
        $output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath -WorkspacePath $candidate -OutputFormat Json 2>&1)
        $report = ($output -join "`n") | ConvertFrom-Json
        Assert-XQ ($report.Tool -eq 'Test-XQDSHEnvironment') 'PowerShell 5.1 default manifest invocation failed'
        Assert-XQ (-not (Test-Path -LiteralPath $candidate)) 'PowerShell 5.1 checker created the workspace'
    }
    It 'does not change PATH, execution policy, or the evaluated workspace' {
        $candidate = Join-Path $TestDrive 'state-not-created'
        $pathBefore = $env:Path
        $policyBefore = @(Get-ExecutionPolicy -List | ForEach-Object { $_.Scope.ToString() + ':' + $_.ExecutionPolicy.ToString() }) -join '|'
        $null = & $scriptPath -WorkspacePath $candidate -ManifestPath $manifestPath -OutputFormat Json
        $policyAfter = @(Get-ExecutionPolicy -List | ForEach-Object { $_.Scope.ToString() + ':' + $_.ExecutionPolicy.ToString() }) -join '|'
        Assert-XQ ($env:Path -ceq $pathBefore) 'PATH changed'
        Assert-XQ ($policyBefore -ceq $policyAfter) 'execution policy changed'
        Assert-XQ (-not (Test-Path -LiteralPath $candidate)) 'workspace changed'
    }
    It 'distinguishes severities and reports privacy-safe metadata only' {
        $candidate = Join-Path $TestDrive 'shape-not-created'
        $report = (& $scriptPath -WorkspacePath $candidate -ManifestPath $manifestPath -OutputFormat Json) | ConvertFrom-Json
        Assert-XQ (@($report.Results | Where-Object { $_.Severity -notin @('INFO','WARNING','BLOCKER','ERROR','UNKNOWN') }).Count -eq 0) 'unknown severity value'
        Assert-XQ (@($report.Results | Where-Object Code -eq 'ADMIN_STATUS').Count -eq 1) 'administrator status missing'
        Assert-XQ (@($report.Results | Where-Object Code -eq 'NPM_CACHE_CHECKED').Count -eq 1) 'cache metadata result missing'
        Assert-XQ (@($report.Results | Where-Object Code -eq 'DSH_HOME_STATUS').Count -eq 1) 'DSH home metadata result missing'
        $json = $report | ConvertTo-Json -Depth 10
        Assert-XQ ($json -notmatch '(?i)DEEPSEEK_API_KEY|Authorization\s*:\s*Bearer|sk-[A-Za-z0-9_-]{8,}') 'sensitive value appeared in report'
    }
    It 'contains no network, install, repair, elevation, or process-stop primitive' {
        $source = [IO.File]::ReadAllText($scriptPath)
        Assert-XQ ($source -notmatch '(?i)Invoke-RestMethod|Invoke-WebRequest|Install-Package|winget|Set-ExecutionPolicy|Start-Process\s+.*RunAs|Stop-Process|taskkill|Remove-Item') 'mutating or network primitive found'
    }
}

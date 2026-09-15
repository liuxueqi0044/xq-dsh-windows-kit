$scriptPath = Join-Path $PSScriptRoot '..\diagnostics\XQ-DSH-Diagnose.ps1'
$schemaPath = Join-Path $PSScriptRoot '..\schemas\diagnostic-report.schema.json'
function Assert-XQ { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

Describe 'M06 read-only diagnostics and redaction' {
    It 'writes a stable, schema-shaped JSON report without creating a workspace' {
        $workspace = Join-Path $TestDrive 'not-created'; $output = Join-Path $TestDrive 'report.json'
        $null = & $scriptPath -WorkspacePath $workspace -OutputPath $output
        Assert-XQ (Test-Path -LiteralPath $output) 'report was not written'
        Assert-XQ (-not (Test-Path -LiteralPath $workspace)) 'diagnostic created workspace'
        $report = [IO.File]::ReadAllText($output,[Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-XQ ($report.tool -eq 'New-XQDSHDiagnosticReport') 'unexpected tool'
        Assert-XQ ($report.dsh.dumpConfig.status -eq 'NOT_RUN') 'dump-config was not blocked'
        Assert-XQ ($report.dsh.dumpConfig.reason -eq 'UPSTREAM_PREPARE_PROFILE_CAN_WRITE') 'dump-config reason changed'
        Assert-XQ (@($report.PSObject.Properties).Count -eq 12) 'top-level whitelist drifted'
    }
    It 'does not overwrite an existing report' {
        $output = Join-Path $TestDrive 'exists.json'; [IO.File]::WriteAllText($output, 'ORIGINAL')
        $null = & $scriptPath -OutputPath $output 2>$null
        Assert-XQ ((Get-Content -LiteralPath $output -Raw) -eq 'ORIGINAL') 'existing report was overwritten'
    }
    It 'redacts the supplied canaries at field and serialized boundaries' {
        Import-Module (Join-Path $PSScriptRoot '..\lib\XQDSH.Common.psm1') -Force
        $canaries = Get-Content (Join-Path $PSScriptRoot 'fixtures\m06-sensitive-canaries.txt') -Raw
        $one = (Protect-XQSensitiveText $canaries).Evidence.Text
        Assert-XQ ($one -notmatch 'FAKE_TEST_(BEARER|PASSWORD|URL_TOKEN)') 'field redaction leaked a canary'
        Assert-XQ ($one -notmatch 'sk-|eyJ[A-Za-z0-9_-]{5,}\.') 'serialized scan leaked a recognized token form'
    }
    It 'contains no network, repair, install, dump-config, or workspace-content read primitive' {
        $source = [IO.File]::ReadAllText($scriptPath)
        Assert-XQ ($source -notmatch '(?i)Invoke-RestMethod|Invoke-WebRequest|Install-Package|winget|Remove-Item|Set-ExecutionPolicy|Start-Process') 'forbidden primitive found'
        Assert-XQ ($source -notmatch '(?i)EnumerateFiles|Get-ChildItem|ReadAllText\([^\r\n]*SKILL') 'workspace or skill-content enumeration primitive found'
    }
    It 'ships a Draft 2020-12 diagnostic schema' {
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        Assert-XQ ($schema.'$schema' -eq 'https://json-schema.org/draft/2020-12/schema') 'schema dialect changed'
        Assert-XQ ($schema.additionalProperties -eq $false) 'schema allows unlisted report fields'
    }
}

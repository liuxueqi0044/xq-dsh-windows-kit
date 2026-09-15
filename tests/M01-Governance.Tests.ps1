$root = Split-Path $PSScriptRoot -Parent
$validator = Join-Path $root 'build\Test-Governance.ps1'
function Assert-XQ { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Read-XQJson { param([string]$Path) Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Write-XQJson { param($Value,[string]$Path) $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8 }

Describe 'M01 governance and manifest' {
    It 'GOV-001 parses every governed JSON document' {
        foreach ($relative in @(
            'manifest/product-manifest.json','manifest/trusted-sources.json',
            'governance/product-scope.json','governance/support-matrix.json','governance/extension-service-policy.json')) {
            try { $null = Read-XQJson (Join-Path $root $relative) } catch { throw ('Invalid JSON: ' + $relative) }
        }
    }

    It 'GOV-001..012 validates the complete approved governance set on Windows PowerShell 5.1' {
        $governed = @(
            'manifest\product-manifest.json','manifest\trusted-sources.json',
            'governance\product-scope.json','governance\support-matrix.json','governance\extension-service-policy.json')
        $before = @($governed | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }) -join '|'
        $output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator 2>&1)
        Assert-XQ ($LASTEXITCODE -eq 0) 'Governance validator rejected the approved files.'
        Assert-XQ (($output -join "`n") -match 'GOVERNANCE_VALID') 'Validator did not emit its stable success code.'
        $after = @($governed | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }) -join '|'
        Assert-XQ ($before -ceq $after) 'Governance validation modified a governed file.'
    }

    It 'GOV-003..009 keeps exact upstream, platform, permission, and privacy locks' {
        $manifest = Read-XQJson (Join-Path $root 'manifest\product-manifest.json')
        Assert-XQ ($manifest.upstream.packageName -ceq '@deepseek-ai/dsh') 'Package lock changed.'
        Assert-XQ ($manifest.upstream.version -ceq '0.1.1-rc.2') 'Version lock changed.'
        Assert-XQ ($manifest.upstream.registry -ceq 'https://registry.npmjs.org/') 'Registry lock changed.'
        Assert-XQ ($manifest.runtime.nodeRange -ceq '>=22.19.0 <23.0.0 || >=24.0.0 <25.0.0') 'Node support lock changed.'
        Assert-XQ ($manifest.runtime.webHost -ceq '127.0.0.1' -and $manifest.runtime.webPort -eq 3080) 'Loopback lock changed.'
        Assert-XQ ($manifest.runtime.sandbox -ceq 'workspace-write' -and $manifest.runtime.approval -ceq 'ask') 'Permission lock changed.'
        Assert-XQ ($manifest.privacy.xqTelemetry -eq $false -and $manifest.privacy.diagnosticsUpload -eq $false -and $manifest.privacy.sessionUpload -eq $false) 'Privacy lock changed.'
    }

    It 'GOV-002 rejects unknown properties at every manifest nesting boundary' {
        $source = Join-Path $root 'manifest\product-manifest.json'
        foreach ($target in @('top','product','upstream','git','license','runtime','privacy','release')) {
            $copy = Read-XQJson $source
            $extra = [pscustomobject]@{ unexpected = $true }
            switch ($target) {
                'top' { Add-Member -InputObject $copy -NotePropertyName unexpected -NotePropertyValue $true }
                'product' { Add-Member -InputObject $copy.product -NotePropertyName unexpected -NotePropertyValue $true }
                'upstream' { Add-Member -InputObject $copy.upstream -NotePropertyName unexpected -NotePropertyValue $true }
                'git' { Add-Member -InputObject $copy.upstream.git -NotePropertyName unexpected -NotePropertyValue $true }
                'license' { Add-Member -InputObject $copy.upstream.license -NotePropertyName unexpected -NotePropertyValue $true }
                'runtime' { Add-Member -InputObject $copy.runtime -NotePropertyName unexpected -NotePropertyValue $true }
                'privacy' { Add-Member -InputObject $copy.privacy -NotePropertyName unexpected -NotePropertyValue $true }
                'release' { Add-Member -InputObject $copy.release -NotePropertyName unexpected -NotePropertyValue $true }
            }
            $path = Join-Path $TestDrive ('unknown-' + $target + '.json')
            Write-XQJson $copy $path
            $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -ManifestPath $path
            Assert-XQ ($LASTEXITCODE -eq 3) ('Unknown property was accepted at ' + $target)
        }
    }

    It 'GOV-002 rejects unknown fields in every other governance document' {
        foreach ($case in @(
            @{ Name='trusted'; Source='manifest\trusted-sources.json'; Parameter='TrustedSourcesPath' },
            @{ Name='scope'; Source='governance\product-scope.json'; Parameter='ProductScopePath' },
            @{ Name='support'; Source='governance\support-matrix.json'; Parameter='SupportMatrixPath' },
            @{ Name='extension'; Source='governance\extension-service-policy.json'; Parameter='ExtensionPolicyPath' })) {
            $copy = Read-XQJson (Join-Path $root $case.Source)
            Add-Member -InputObject $copy -NotePropertyName unexpected -NotePropertyValue $true
            $path = Join-Path $TestDrive ($case.Name + '.json')
            Write-XQJson $copy $path
            $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$validator,('-' + $case.Parameter),$path)
            $null = & powershell.exe @arguments
            Assert-XQ ($LASTEXITCODE -eq 3) ('Unknown governance property was accepted: ' + $case.Name)
        }
    }

    It 'GOV-010 and GOV-011 rejects release without all human gate evidence' {
        $path = Join-Path $TestDrive 'releasable.json'
        $manifest = Read-XQJson (Join-Path $root 'manifest\product-manifest.json')
        $manifest.release.state = 'releasable'
        Write-XQJson $manifest $path
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -ManifestPath $path
        Assert-XQ ($LASTEXITCODE -eq 3) 'Releasable state without gate evidence was accepted.'
    }

    It 'GOV-003..007 rejects floating versions, alternate sources, unsafe runtime, and altered hashes' {
        foreach ($case in @('latest','registry','host','permission','hash')) {
            $path = Join-Path $TestDrive ($case + '.json')
            $manifest = Read-XQJson (Join-Path $root 'manifest\product-manifest.json')
            switch ($case) {
                'latest' { $manifest.upstream.version = 'latest' }
                'registry' { $manifest.upstream.registry = 'https://example.invalid/' }
                'host' { $manifest.runtime.webHost = '0.0.0.0' }
                'permission' { $manifest.runtime.sandbox = 'danger-full-access'; $manifest.runtime.approval = 'never' }
                'hash' { $manifest.upstream.sha256 = ('0' * 64) }
            }
            Write-XQJson $manifest $path
            $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validator -ManifestPath $path
            Assert-XQ ($LASTEXITCODE -eq 3) ('Unsafe case was accepted: ' + $case)
        }
    }
}

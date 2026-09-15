[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$TrustedSourcesPath,
    [string]$ProductScopePath,
    [string]$SupportMatrixPath,
    [string]$ExtensionPolicyPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $base '..\manifest\product-manifest.json' }
if ([string]::IsNullOrWhiteSpace($TrustedSourcesPath)) { $TrustedSourcesPath = Join-Path $base '..\manifest\trusted-sources.json' }
if ([string]::IsNullOrWhiteSpace($ProductScopePath)) { $ProductScopePath = Join-Path $base '..\governance\product-scope.json' }
if ([string]::IsNullOrWhiteSpace($SupportMatrixPath)) { $SupportMatrixPath = Join-Path $base '..\governance\support-matrix.json' }
if ([string]::IsNullOrWhiteSpace($ExtensionPolicyPath)) { $ExtensionPolicyPath = Join-Path $base '..\governance\extension-service-policy.json' }

function Write-XQGovernanceResult {
    param([string]$Status, [string]$Code, [string[]]$Errors)
    [pscustomobject][ordered]@{ status=$Status; code=$Code; errors=@($Errors) } | ConvertTo-Json -Depth 5
    if ($Status -ne 'PASS') { exit 3 }
}

function Read-XQGovernedJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw [System.IO.FileNotFoundException]::new('Governed JSON is missing.') }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
}

function Test-XQExactProperties {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $false }
    $actual = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    return (@($actual | Where-Object { $Names -notcontains $_ }).Count -eq 0 -and
        @($Names | Where-Object { $actual -notcontains $_ }).Count -eq 0)
}

function Test-XQExactStringSet {
    param($Actual, [string[]]$Expected)
    $values = @($Actual)
    if ($values.Count -ne $Expected.Count) { return $false }
    foreach ($item in $Expected) { if (@($values | Where-Object { $_ -ceq $item }).Count -ne 1) { return $false } }
    return $true
}

function Add-XQError {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { $script:validationErrors += $Code }
}

try {
    $manifest = Read-XQGovernedJson $ManifestPath
    $trusted = Read-XQGovernedJson $TrustedSourcesPath
    $scope = Read-XQGovernedJson $ProductScopePath
    $support = Read-XQGovernedJson $SupportMatrixPath
    $extension = Read-XQGovernedJson $ExtensionPolicyPath
    $script:validationErrors = @()

    Add-XQError (Test-XQExactProperties $manifest @('$schema','product','upstream','runtime','privacy','release')) 'MANIFEST_FIELDS'
    Add-XQError (Test-XQExactProperties $manifest.product @('name','version','brandClaimsVersion')) 'PRODUCT_FIELDS'
    Add-XQError (Test-XQExactProperties $manifest.upstream @('packageName','version','registry','tarball','integrity','sha256','git','license')) 'UPSTREAM_FIELDS'
    Add-XQError (Test-XQExactProperties $manifest.upstream.git @('repository','tag','commit')) 'GIT_FIELDS'
    Add-XQError (Test-XQExactProperties $manifest.upstream.license @('spdx','url','sha256')) 'LICENSE_FIELDS'
    Add-XQError (Test-XQExactProperties $manifest.runtime @('operatingSystem','architecture','nodeRange','webHost','webPort','sandbox','approval')) 'RUNTIME_FIELDS'
    Add-XQError (Test-XQExactProperties $manifest.privacy @('xqTelemetry','diagnosticsUpload','sessionUpload')) 'PRIVACY_FIELDS'
    Add-XQError (Test-XQExactProperties $manifest.release @('state','lockedAtUtc','requiredGates','approvalReference','gateEvidence')) 'RELEASE_FIELDS'

    Add-XQError ($manifest.'$schema' -ceq '../schemas/product-manifest.schema.json' -and
        $manifest.product.name -ceq 'XQ DSH Windows Kit' -and $manifest.product.version -ceq '1.0.0' -and
        $manifest.product.brandClaimsVersion -ceq '1') 'PRODUCT_VALUES'
    Add-XQError ($manifest.upstream.packageName -ceq '@deepseek-ai/dsh' -and
        $manifest.upstream.version -ceq '0.1.1-rc.2' -and
        $manifest.upstream.registry -ceq 'https://registry.npmjs.org/') 'PACKAGE_VALUES'
    Add-XQError ($manifest.upstream.tarball -ceq 'https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.1-rc.2.tgz' -and
        $manifest.upstream.integrity -ceq 'sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg==' -and
        $manifest.upstream.sha256 -ceq '47ec05f45ada5ab87779ae18a90456b5ebff5421dc0ff5c179677d65e1c16057') 'ARTIFACT_VALUES'
    Add-XQError ($manifest.upstream.git.repository -ceq 'https://github.com/deepseek-ai/deepseek-harness.git' -and
        $manifest.upstream.git.tag -ceq 'dsh-v0.1.1-rc.2' -and
        $manifest.upstream.git.commit -ceq 'b150a551b8d465e31e418e1b2eaf5e79bbb7d28e') 'GIT_VALUES'
    Add-XQError ($manifest.upstream.license.spdx -ceq 'MIT' -and
        $manifest.upstream.license.url -ceq 'https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/dsh-v0.1.1-rc.2/LICENSE' -and
        $manifest.upstream.license.sha256 -ceq 'ebb4f09972aee8608be255debaf78451a68e95c290f55c240dec2ecfa16ea6be') 'LICENSE_VALUES'
    Add-XQError ($manifest.runtime.operatingSystem -ceq 'Windows 11' -and $manifest.runtime.architecture -ceq 'x64' -and
        $manifest.runtime.nodeRange -ceq '>=22.19.0 <23.0.0 || >=24.0.0 <25.0.0' -and
        $manifest.runtime.webHost -ceq '127.0.0.1' -and $manifest.runtime.webPort -eq 3080 -and
        $manifest.runtime.sandbox -ceq 'workspace-write' -and $manifest.runtime.approval -ceq 'ask') 'RUNTIME_VALUES'
    Add-XQError ($manifest.privacy.xqTelemetry -eq $false -and $manifest.privacy.diagnosticsUpload -eq $false -and
        $manifest.privacy.sessionUpload -eq $false) 'PRIVACY_VALUES'

    $lockedAt = [DateTimeOffset]::MinValue
    $lockedAtValid = [DateTimeOffset]::TryParseExact([string]$manifest.release.lockedAtUtc, 'yyyy-MM-ddTHH:mm:ssZ',
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$lockedAt)
    Add-XQError ($manifest.release.state -in @('draft','candidate','releasable') -and $lockedAtValid -and
        (Test-XQExactStringSet $manifest.release.requiredGates @('upstream-lock','vm-zh','vm-en','human-review'))) 'RELEASE_VALUES'
    if ($null -ne $manifest.release.approvalReference) {
        Add-XQError (-not [string]::IsNullOrWhiteSpace([string]$manifest.release.approvalReference)) 'APPROVAL_REFERENCE'
    }
    if ($null -ne $manifest.release.gateEvidence) {
        Add-XQError (Test-XQExactProperties $manifest.release.gateEvidence @('upstream-lock','vm-zh','vm-en','human-review')) 'GATE_EVIDENCE_FIELDS'
        foreach ($gate in @('upstream-lock','vm-zh','vm-en','human-review')) {
            $property = $manifest.release.gateEvidence.PSObject.Properties[$gate]
            Add-XQError ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) ('GATE_' + $gate)
        }
    }
    if ($manifest.release.state -eq 'releasable') {
        Add-XQError (-not [string]::IsNullOrWhiteSpace([string]$manifest.release.approvalReference) -and
            $null -ne $manifest.release.gateEvidence) 'RELEASE_EVIDENCE'
    }

    Add-XQError (Test-XQExactProperties $trusted @('$schema','npmRegistry','officialHosts','packageName','repository','tagPattern','allowRedirects')) 'TRUSTED_FIELDS'
    Add-XQError ($trusted.'$schema' -ceq '../schemas/trusted-sources.schema.json' -and
        $trusted.npmRegistry -ceq 'https://registry.npmjs.org/' -and $trusted.packageName -ceq '@deepseek-ai/dsh' -and
        $trusted.repository -ceq 'deepseek-ai/deepseek-harness' -and $trusted.tagPattern -ceq '^dsh-v0\.1\.1-rc\.2$' -and
        $trusted.allowRedirects -eq $false -and
        (Test-XQExactStringSet $trusted.officialHosts @('registry.npmjs.org','github.com','raw.githubusercontent.com'))) 'TRUSTED_VALUES'

    Add-XQError (Test-XQExactProperties $scope @('$schema','supportedOperatingSystems','supportedArchitectures','distributionIncludesPluginInstaller','claims')) 'SCOPE_FIELDS'
    Add-XQError (Test-XQExactProperties $scope.claims @('securityAudit','sandbox','publicService')) 'CLAIMS_FIELDS'
    Add-XQError ($scope.'$schema' -ceq '../schemas/product-scope.schema.json' -and
        (Test-XQExactStringSet $scope.supportedOperatingSystems @('Windows 11')) -and
        (Test-XQExactStringSet $scope.supportedArchitectures @('x64')) -and
        $scope.distributionIncludesPluginInstaller -eq $false -and $scope.claims.securityAudit -ceq 'not-claimed' -and
        $scope.claims.sandbox -ceq 'partial-restriction' -and $scope.claims.publicService -ceq 'not-provided') 'SCOPE_VALUES'

    Add-XQError (Test-XQExactProperties $support @('$schema','nodeRanges','supportedOperatingSystems','supportedArchitectures','supportStatus')) 'SUPPORT_FIELDS'
    Add-XQError ($support.'$schema' -ceq '../schemas/support-matrix.schema.json' -and
        (Test-XQExactStringSet $support.nodeRanges @('>=22.19.0 <23.0.0','>=24.0.0 <25.0.0')) -and
        (Test-XQExactStringSet $support.supportedOperatingSystems @('Windows 11')) -and
        (Test-XQExactStringSet $support.supportedArchitectures @('x64')) -and $support.supportStatus -ceq 'preview') 'SUPPORT_VALUES'

    Add-XQError (Test-XQExactProperties $extension @('$schema','defaultDisposition','operatorOnly','blockedConditions','requiredChecks')) 'EXTENSION_FIELDS'
    Add-XQError ($extension.'$schema' -ceq '../schemas/extension-service-policy.schema.json' -and
        $extension.defaultDisposition -ceq 'deny' -and $extension.operatorOnly -eq $true -and
        (Test-XQExactStringSet $extension.blockedConditions @('git-source','unknown-lifecycle-script','native-binary','browser-driver','background-service','oauth','paid-api','allowBuilds')) -and
        (Test-XQExactStringSet $extension.requiredChecks @('exact-version','tarball','integrity','package-scripts','license','backup','rollback'))) 'EXTENSION_VALUES'

    if ($script:validationErrors.Count -gt 0) { Write-XQGovernanceResult 'FAIL' 'GOVERNANCE_INVALID' $script:validationErrors }
    Write-XQGovernanceResult 'PASS' 'GOVERNANCE_VALID' @()
} catch {
    Write-XQGovernanceResult 'FAIL' 'GOVERNANCE_INPUT_ERROR' @($_.Exception.GetType().Name)
}

$root = Split-Path $PSScriptRoot -Parent
$verify = Join-Path $root 'build\Verify-NpmArtifact.ps1'
$resolve = Join-Path $root 'build\Resolve-OfficialPackage.ps1'
function Assert-XQ { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

function Set-XQAsciiBytes {
    param([byte[]]$Buffer,[int]$Offset,[int]$Length,[string]$Text)
    $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
    if ($bytes.Length -gt $Length) { throw 'Tar header field is too long.' }
    [Array]::Copy($bytes, 0, $Buffer, $Offset, $bytes.Length)
}

function New-XQTraversalTarGzip {
    param([string]$Path)
    $header = New-Object byte[] 512
    Set-XQAsciiBytes $header 0 100 '../escape.txt'
    Set-XQAsciiBytes $header 100 8 "0000644`0"
    Set-XQAsciiBytes $header 108 8 "0000000`0"
    Set-XQAsciiBytes $header 116 8 "0000000`0"
    Set-XQAsciiBytes $header 124 12 "00000000001`0"
    Set-XQAsciiBytes $header 136 12 "00000000000`0"
    for ($index = 148; $index -lt 156; $index++) { $header[$index] = 32 }
    $header[156] = [byte][char]'0'
    Set-XQAsciiBytes $header 257 6 "ustar`0"
    Set-XQAsciiBytes $header 263 2 '00'
    $checksum = 0
    foreach ($value in $header) { $checksum += [int]$value }
    Set-XQAsciiBytes $header 148 8 (([Convert]::ToString($checksum, 8).PadLeft(6, '0')) + "`0 ")
    $archive = New-Object byte[] 2048
    [Array]::Copy($header, 0, $archive, 0, 512)
    $archive[512] = [byte][char]'x'
    $stream = [IO.File]::Create($Path)
    try {
        $gzip = New-Object IO.Compression.GzipStream($stream, [IO.Compression.CompressionMode]::Compress, $true)
        try { $gzip.Write($archive, 0, $archive.Length) } finally { $gzip.Dispose() }
    } finally { $stream.Dispose() }
}

Describe 'M02 supply-chain scripts' {
    It 'SUP-001, SUP-002, and SUP-010 keep the exact official source policy' {
        $trusted = Get-Content (Join-Path $root 'manifest\trusted-sources.json') -Raw | ConvertFrom-Json
        Assert-XQ ($trusted.npmRegistry -ceq 'https://registry.npmjs.org/') 'Registry allowlist changed.'
        Assert-XQ ($trusted.packageName -ceq '@deepseek-ai/dsh') 'Package allowlist changed.'
        Assert-XQ ($trusted.repository -ceq 'deepseek-ai/deepseek-harness') 'Repository allowlist changed.'
        Assert-XQ ($trusted.allowRedirects -eq $false) 'Redirect policy changed.'
        Assert-XQ (@($trusted.officialHosts).Count -eq 3) 'Official host set changed.'
    }

    It 'SUP-006..015 records tag, license, package metadata, provenance limits, and CLI evidence without npm execution' {
        $source = Get-Content -LiteralPath $resolve -Raw
        Assert-XQ ($source -match 'ls-remote') 'Git tag observation is missing.'
        Assert-XQ ($source -match 'licenseSha256') 'License evidence is missing.'
        Assert-XQ ($source -match 'inside\.bin\.dsh') 'Package bin evidence is missing.'
        Assert-XQ ($source -match "provenance='UNAVAILABLE'") 'Unavailable provenance is not explicit.'
        Assert-XQ ($source -match 'directDependencyRanges') 'Dependency range risk is not recorded.'
        Assert-XQ ($source -notmatch '(?i)npm\s+(install|exec)|&\s*(npm|npx)(\.cmd)?\b|Invoke-Expression|Start-Process') 'Resolver can execute npm package code.'
        Assert-XQ (Test-Path (Join-Path $root 'docs\evidence\upstream-cli-contract.md')) 'CLI contract evidence is missing.'
    }

    It 'SUP-003, SUP-004, and SUP-009 verifies the real locked artifact and rejects one changed byte' {
        $manifest = Get-Content (Join-Path $root 'manifest\product-manifest.json') -Raw | ConvertFrom-Json
        $tarball = Join-Path $TestDrive 'artifact.tgz'
        Invoke-WebRequest -Uri $manifest.upstream.tarball -OutFile $tarball -UseBasicParsing
        $ok = Join-Path $TestDrive 'verified.json'
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verify -TarballPath $tarball -OutputPath $ok
        Assert-XQ ($LASTEXITCODE -eq 0) 'The real locked artifact did not verify.'
        $result = Get-Content $ok -Raw | ConvertFrom-Json
        Assert-XQ ($result.status -eq 'PASS' -and $result.checks.sha256 -and $result.checks.integrity -and $result.checks.safeTarPaths) 'Verification evidence is incomplete.'

        $bytes = [IO.File]::ReadAllBytes($tarball)
        $bytes[20] = $bytes[20] -bxor 1
        [IO.File]::WriteAllBytes($tarball, $bytes)
        $bad = Join-Path $TestDrive 'changed-byte.json'
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verify -TarballPath $tarball -OutputPath $bad
        Assert-XQ ($LASTEXITCODE -eq 2) 'A changed artifact byte was accepted.'
    }

    It 'SUP-005 rejects a real tar entry containing parent traversal' {
        $tarball = Join-Path $TestDrive 'path-traversal.tgz'
        New-XQTraversalTarGzip $tarball
        $listing = @(& tar.exe -tzf $tarball 2>&1)
        Assert-XQ ($LASTEXITCODE -eq 0 -and ($listing -join "`n") -match '\.\./escape\.txt') 'Traversal tar fixture was not constructed correctly.'
        $resultPath = Join-Path $TestDrive 'path-traversal.json'
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verify -TarballPath $tarball -OutputPath $resultPath
        Assert-XQ ($LASTEXITCODE -eq 2) 'Traversal tar was accepted.'
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        Assert-XQ ($result.checks.safeTarPaths -eq $false) 'Traversal failure was not attributed to tar paths.'
    }

    It 'SUP-003 refuses a manifest that redefines the trusted artifact hash' {
        $manifestPath = Join-Path $TestDrive 'altered-manifest.json'
        $manifest = Get-Content (Join-Path $root 'manifest\product-manifest.json') -Raw | ConvertFrom-Json
        $manifest.upstream.sha256 = ('0' * 64)
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $dummy = Join-Path $TestDrive 'dummy.tgz'
        [IO.File]::WriteAllBytes($dummy, [byte[]](1,2,3,4))
        $resultPath = Join-Path $TestDrive 'untrusted-manifest.json'
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verify -ManifestPath $manifestPath -TarballPath $dummy -OutputPath $resultPath
        Assert-XQ ($LASTEXITCODE -eq 3) 'Verifier trusted a caller-redefined hash.'
        Assert-XQ ((Get-Content $resultPath -Raw | ConvertFrom-Json).code -eq 'UNTRUSTED_MANIFEST') 'Wrong failure code for an untrusted manifest.'
    }

    It 'SUP-010 rejects an alternate registry before creating staging or using the network' {
        $trustedPath = Join-Path $TestDrive 'alternate-registry.json'
        $trusted = Get-Content (Join-Path $root 'manifest\trusted-sources.json') -Raw | ConvertFrom-Json
        $trusted.npmRegistry = 'https://registry.example.invalid/'
        $trusted | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $trustedPath -Encoding UTF8
        $outputDirectory = Join-Path $TestDrive 'must-not-exist'
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $resolve -TrustedSourcesPath $trustedPath -OutputDirectory $outputDirectory
        Assert-XQ ($LASTEXITCODE -eq 3) 'Alternate registry policy was accepted.'
        Assert-XQ (-not (Test-Path -LiteralPath $outputDirectory)) 'Resolver created staging before trust validation.'
    }
}

[CmdletBinding()]
param(
  [string]$ManifestPath,
  [string]$TrustedSourcesPath,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $PSScriptRoot '..\manifest\product-manifest.json' }
if ([string]::IsNullOrWhiteSpace($TrustedSourcesPath)) { $TrustedSourcesPath = Join-Path $PSScriptRoot '..\manifest\trusted-sources.json' }
function Fail([int]$ExitCode, [string]$Code, [string]$Message) { [pscustomobject]@{status='FAIL';code=$Code;message=$Message} | ConvertTo-Json -Compress; exit $ExitCode }
function Read-Json([string]$Path) { if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { Fail 3 'INPUT_MISSING' 'Required JSON input is missing.' }; Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Test-AllowedUri([string]$Value, [object]$Trusted) { try { $u=[Uri]$Value } catch { return $false }; return $u.Scheme -eq 'https' -and ($Trusted.officialHosts -contains $u.Host) }
function Get-LowerHash([string]$Path, [string]$Algorithm) { return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant() }
function Get-Sri([string]$Path) { $fs=[IO.File]::OpenRead($Path); try { $bytes=[Security.Cryptography.SHA512]::Create().ComputeHash($fs) } finally { $fs.Dispose() }; return 'sha512-' + [Convert]::ToBase64String($bytes) }
function Test-TarEntry([string]$Entry) { return !([string]::IsNullOrWhiteSpace($Entry) -or $Entry.StartsWith('/') -or $Entry.StartsWith('\\') -or $Entry -match '^[A-Za-z]:' -or ($Entry -split '[\\/]') -contains '..') }
try {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-Governance.ps1') -ManifestPath $ManifestPath -TrustedSourcesPath $TrustedSourcesPath | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail 3 'UNTRUSTED_MANIFEST' 'Manifest or trusted-source governance validation failed.' }
  $manifest=Read-Json $ManifestPath; $trusted=Read-Json $TrustedSourcesPath
  $expectedTarball=$trusted.npmRegistry.TrimEnd('/') + '/@deepseek-ai/dsh/-/dsh-0.1.1-rc.2.tgz'; $expectedGit='https://github.com/' + $trusted.repository + '.git'; $expectedLicense='https://raw.githubusercontent.com/' + $trusted.repository + '/dsh-v0.1.1-rc.2/LICENSE'
  if ($manifest.upstream.packageName -ne $trusted.packageName -or $manifest.upstream.registry -ne $trusted.npmRegistry -or $manifest.upstream.tarball -ne $expectedTarball -or $manifest.upstream.git.repository -ne $expectedGit -or $manifest.upstream.license.url -ne $expectedLicense -or !(Test-AllowedUri $manifest.upstream.tarball $trusted) -or !(Test-AllowedUri $manifest.upstream.license.url $trusted) -or !(Test-AllowedUri $manifest.upstream.git.repository $trusted) -or $manifest.upstream.git.tag -notmatch $trusted.tagPattern) { Fail 3 'TRUST_ROOT_INVALID' 'Manifest does not match the immutable trusted source policy.' }
  New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
  $stage=Join-Path $OutputDirectory ('staging-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $stage | Out-Null
  $encoded=[Uri]::EscapeDataString($manifest.upstream.packageName)
  $metadataUri=$trusted.npmRegistry.TrimEnd('/') + '/' + $encoded + '/' + $manifest.upstream.version
  $packumentUri=$trusted.npmRegistry.TrimEnd('/') + '/' + $encoded
  if (!(Test-AllowedUri $metadataUri $trusted) -or !(Test-AllowedUri $packumentUri $trusted)) { Fail 3 'URL_DENIED' 'A constructed registry URL is outside the allowlist.' }
  $metadata=Invoke-RestMethod -Uri $metadataUri -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 30
  $packument=Invoke-RestMethod -Uri $packumentUri -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 30
  if (!(Test-AllowedUri $metadata.dist.tarball $trusted)) { Fail 2 'METADATA_TARBALL_DENIED' 'Registry metadata named a tarball outside the allowlist.' }
  $tarball=Join-Path $stage 'artifact.tgz'; Invoke-WebRequest -Uri $manifest.upstream.tarball -OutFile $tarball -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 60
  $entries=& tar.exe -tzf $tarball; if ($LASTEXITCODE -ne 0 -or @($entries | Where-Object { !(Test-TarEntry $_) }).Count -gt 0) { Fail 2 'TAR_PATH_ESCAPE' 'Tar listing failed or contained an unsafe entry.' }
  $packageJson=Join-Path $stage 'package.json'; & tar.exe -xOzf $tarball 'package/package.json' | Set-Content -LiteralPath $packageJson -Encoding UTF8; if ($LASTEXITCODE -ne 0) { Fail 2 'TAR_FORMAT_INVALID' 'Unable to extract package metadata.' }; $inside=Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
  $license=Join-Path $stage 'LICENSE'; Invoke-WebRequest -Uri $manifest.upstream.license.url -OutFile $license -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 30
  $remote=(& git -c http.sslBackend=openssl -c credential.interactive=never ls-remote $manifest.upstream.git.repository ('refs/tags/' + $manifest.upstream.git.tag)); if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) { Fail 4 'GIT_REF_UNAVAILABLE' 'Official tag ref could not be observed.' }; $commit=($remote -split '\s+')[0].ToLowerInvariant()
  $checks=[ordered]@{ packageName=($metadata.name -eq $manifest.upstream.packageName -and $inside.name -eq $manifest.upstream.packageName); version=($metadata.version -eq $manifest.upstream.version -and $inside.version -eq $manifest.upstream.version); registry=$true; tarball=($metadata.dist.tarball -eq $manifest.upstream.tarball); integrity=($metadata.dist.integrity -eq $manifest.upstream.integrity -and (Get-Sri $tarball) -eq $manifest.upstream.integrity); sha256=((Get-LowerHash $tarball SHA256) -eq $manifest.upstream.sha256); tagCommit=($commit -eq $manifest.upstream.git.commit); license=((Get-LowerHash $license SHA256) -eq $manifest.upstream.license.sha256); packageMetadata=($inside.license -eq $manifest.upstream.license.spdx -and $inside.repository.url -eq 'git+https://github.com/deepseek-ai/deepseek-harness.git' -and $inside.bin.dsh -eq 'lib/bin.js') }
  $gitHeadProperty=$metadata.PSObject.Properties['gitHead']; $gitHead=if ($null -ne $gitHeadProperty -and $gitHeadProperty.Value) {$gitHeadProperty.Value} else {'UNAVAILABLE'}
  $versionsProperty=$packument.PSObject.Properties['versions']; $candidateExists=($null -ne $versionsProperty -and $null -ne $versionsProperty.Value.PSObject.Properties[$manifest.upstream.version])
  $tagsProperty=$packument.PSObject.Properties['dist-tags']; $latest=if($null -ne $tagsProperty -and $null -ne $tagsProperty.Value.PSObject.Properties['latest']){$tagsProperty.Value.latest}else{'UNAVAILABLE'}; $next=if($null -ne $tagsProperty -and $null -ne $tagsProperty.Value.PSObject.Properties['next']){$tagsProperty.Value.next}else{'UNAVAILABLE'}
  $observation=[ordered]@{ schemaVersion='1'; observedAtUtc=[DateTime]::UtcNow.ToString('o'); status=if (($checks.Values -notcontains $false) -and $candidateExists) {'PASS'} else {'MISMATCH'}; source=[ordered]@{registry=$trusted.npmRegistry; metadataUri=$metadataUri; packumentUri=$packumentUri; tarball=$metadata.dist.tarball; tag=$manifest.upstream.git.tag; commit=$commit}; distTags=[ordered]@{latest=$latest;next=$next;candidateVersion=$manifest.upstream.version;candidateExists=$candidateExists;selection='exact-version endpoint; dist-tags are observed only and never selected'}; artifact=[ordered]@{integrity=$metadata.dist.integrity; sha256=(Get-LowerHash $tarball SHA256); licenseSha256=(Get-LowerHash $license SHA256); gitHead=$gitHead; provenance='UNAVAILABLE'; directDependencyRanges=$inside.dependencies}; checks=$checks; risks=@('Top-level npm artifact is locked; npx may still resolve transitive dependency ranges from upstream.','No gitHead/provenance field was observed; tarball-to-commit cryptographic binding is unavailable.'); staging=$stage }
  Copy-Item -LiteralPath $license -Destination (Join-Path $OutputDirectory 'upstream-LICENSE.txt') -Force
  $observation | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'source-observation.json') -Encoding UTF8
  $observation | ConvertTo-Json -Depth 20
  if ($observation.status -ne 'PASS') { exit 2 }
} catch { if ($_.Exception -is [System.Net.WebException] -or $_.Exception.GetType().Name -eq 'HttpRequestException') { Fail 4 'NETWORK_FAILURE' 'Official source network request failed.' } elseif ($_.Exception -is [System.Management.Automation.CommandNotFoundException]) { Fail 4 'REQUIRED_TOOL_MISSING' 'A required read-only tool is not available.' } elseif ($_.Exception -is [System.Management.Automation.RuntimeException]) { Fail 3 'INPUT_OR_FORMAT_INVALID' 'Manifest, metadata, or tar format was invalid.' } else { Fail 5 'OBSERVATION_INTERNAL_ERROR' 'Unexpected observation failure.' } }

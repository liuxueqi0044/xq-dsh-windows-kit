$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'build/Build-Package.ps1'
function Assert-XQ { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
Describe 'M09 explicit-whitelist package build' {
  It 'BLD-001/002 builds only the declared layout into a development artifact' {
    $out=Join-Path $TestDrive 'out'; $null=& $build -Root $root -OutputRoot $out
    $zip=Join-Path $out 'XQ-DSH-Windows-v1.0.0.zip'; Assert-XQ (Test-Path $zip) 'zip missing'
    $directory=Join-Path $out 'XQ-DSH-Windows-v1.0.0'; Assert-XQ (Test-Path $directory -PathType Container) 'package directory missing'
    foreach($required in @('00-开始这里.html','01-环境检查/Test-XQDSHEnvironment.ps1','01-环境检查/使用说明.html','02-启动工具/Start-XQDSH.ps1','02-启动工具/启动与停止.html','04-诊断工具/XQ-DSH-Diagnose.ps1','06-许可与来源/SOURCE-AND-VERSION.json','06-许可与来源/SHA256SUMS.txt','README.txt','_internal/lib/XQDSH.Common.psm1','_internal/manifest/product-manifest.json','_internal/launcher/XQ-DSH-Safe.patch.yml')) { Assert-XQ (Test-Path (Join-Path $directory $required)) ('missing mapped file: '+$required) }
    foreach($scriptRelative in @('01-环境检查/Test-XQDSHEnvironment.ps1','02-启动工具/Start-XQDSH.ps1','04-诊断工具/XQ-DSH-Diagnose.ps1')) { $scriptPath=Join-Path $directory $scriptRelative;$bytes=[IO.File]::ReadAllBytes($scriptPath); Assert-XQ ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('packaged script is not PS5.1-safe UTF-8 BOM: '+$scriptRelative);$scriptText=[IO.File]::ReadAllText($scriptPath,[Text.Encoding]::UTF8);Assert-XQ ($scriptText -match '\.\.\\_internal\\lib\\XQDSH\.Common\.psm1' -and $scriptText -match '\.\.\\_internal\\manifest\\product-manifest\.json') ('packaged runtime paths were not rewritten: '+$scriptRelative) }
    Assert-XQ (([IO.File]::ReadAllText((Join-Path $directory 'README.txt'),[Text.Encoding]::UTF8)) -match '离线中文指南') 'package README is not the offline user guide'
    Add-Type -AssemblyName System.IO.Compression.FileSystem; $a=[IO.Compression.ZipFile]::OpenRead($zip); try {$names=@($a.Entries|ForEach-Object FullName)} finally {$a.Dispose()}
    $directoryNames=@(Get-ChildItem -LiteralPath $directory -Recurse -File | ForEach-Object {$_.FullName.Substring($directory.Length).TrimStart('\','/').Replace('\','/')}); Assert-XQ ((@($names | Sort-Object) -join '|') -eq (@($directoryNames | Sort-Object) -join '|')) 'directory and ZIP content differ'
    Assert-XQ ($names -contains '06-许可与来源/SHA256SUMS.txt') 'internal hashes missing'; Assert-XQ ($names -notcontains 'extensions/Test-XQDSHSkill.ps1') 'operator tool included'; Assert-XQ (@($names -match '(^|/)(tests|extensions|acceptance|node_modules)/').Count -eq 0) 'forbidden directory included'
  }
  It 'BLD-008/009/010 writes matching internal and external hashes without self reference' {
    $out=Join-Path $TestDrive 'hash'; $null=& $build -Root $root -OutputRoot $out; $release=Get-Content (Join-Path $out 'release-manifest.json') -Raw|ConvertFrom-Json
    $actual=(Get-FileHash (Join-Path $out $release.zipFile) -Algorithm SHA256).Hash.ToLowerInvariant();Assert-XQ ($release.zipSha256 -eq $actual) 'external hash mismatch'; Assert-XQ ((Get-Content (Join-Path $out 'SHA256SUMS.txt') -Raw).Trim() -eq ($actual+'  '+$release.zipFile)) 'external SHA256SUMS does not identify the ZIP'; Assert-XQ ($release.selfReference -eq $false) 'self reference claimed'
  }
  It 'BLD-003/004/012 refuses candidate output without an M10 PASS gate and remains development' {
    $out=Join-Path $TestDrive 'candidate'; $null=& $build -Root $root -OutputRoot $out -Candidate 2>$null; Assert-XQ (-not (Test-Path (Join-Path $out 'XQ-DSH-Windows-v1.0.0.zip'))) 'candidate built without gate'
    $dev=Join-Path $TestDrive 'dev'; $null=& $build -Root $root -OutputRoot $dev; $r=Get-Content (Join-Path $dev 'release-manifest.json') -Raw|ConvertFrom-Json; Assert-XQ ($r.buildKind -eq 'development' -and $r.productReleaseState -eq 'draft') 'development build made release claim'
  }
  It 'rejects forged or incomplete candidate gates without leaving outputs' {
    $manifest=Join-Path $root 'manifest/product-manifest.json'; $observation='docs/evidence/upstream-cli-contract.md'; $hash=(Get-FileHash $manifest -Algorithm SHA256).Hash.ToLowerInvariant(); $obHash=(Get-FileHash (Join-Path $root $observation) -Algorithm SHA256).Hash.ToLowerInvariant()
    $bad=Join-Path $TestDrive 'bad-gate.json'; [IO.File]::WriteAllText($bad, ('{"schema":"xq.m10.prebuild-gate.v1","status":"PASS","manifestSha256":"'+$hash+'","sourceObservation":{"path":"'+$observation+'","sha256":"'+$obHash+'","status":"PASS"},"prebuildResults":[{"id":"M09","status":"FAIL"}]}'))
    $out=Join-Path $TestDrive 'forged'; $null=& $build -Root $root -OutputRoot $out -Candidate -PreBuildGatePath $bad 2>$null; Assert-XQ (-not (Test-Path (Join-Path $out 'XQ-DSH-Windows-v1.0.0.zip'))) 'forged gate created output'
    $incomplete=Join-Path $TestDrive 'incomplete-gate.json'; [IO.File]::WriteAllText($incomplete,'{"schema":"xq.m10.prebuild-gate.v1","status":"PASS"}')
    $out2=Join-Path $TestDrive 'incomplete'; $null=& $build -Root $root -OutputRoot $out2 -Candidate -PreBuildGatePath $incomplete 2>$null; Assert-XQ (-not (Test-Path $out2)) 'incomplete gate left output root'
  }
  It 'BLD-005/006/007 refuses unsafe layout paths and scans source text' {
    $source=[IO.File]::ReadAllText($build); Assert-XQ ($source -match 'Test-XQSensitivePackageFile' -and $source -match 'Unsafe ZIP entry path') 'safety scans absent'; Assert-XQ ($source -notmatch 'Copy-Item\s+-Recurse') 'recursive copy bypasses whitelist'
  }
  It 'BLD-011 uses stable ZIP ordering and timestamps' {
    $a=Join-Path $TestDrive 'a';$b=Join-Path $TestDrive 'b';$null=& $build -Root $root -OutputRoot $a;$null=& $build -Root $root -OutputRoot $b
    Assert-XQ ((Get-FileHash (Join-Path $a 'XQ-DSH-Windows-v1.0.0.zip') -Algorithm SHA256).Hash -eq (Get-FileHash (Join-Path $b 'XQ-DSH-Windows-v1.0.0.zip') -Algorithm SHA256).Hash) 'ZIP output is not deterministic'
  }
}

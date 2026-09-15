$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$skill=Join-Path $root 'extensions/Test-XQDSHSkill.ps1'
$plugin=Join-Path $root 'extensions/Test-XQDSHPluginPackage.ps1'
Describe 'M08 extension service static audit' {
    It 'EXT-001 rejects inconsistent skill metadata' { $x=& $skill (Join-Path $root 'tests/fixtures/m08/bad-skill'); $x.Passed | Should Be $false; ((@($x.Results.Code) -contains 'SKILL_NAME_MISMATCH')) | Should Be $true }
    It 'EXT-002 rejects resource escape' { $x=& $skill (Join-Path $root 'tests/fixtures/m08/bad-skill'); ((@($x.Results.Code) -contains 'SKILL_RESOURCE_ESCAPE')) | Should Be $true }
    It 'EXT-003 rejects recognized secret patterns' { $x=& $skill (Join-Path $root 'tests/fixtures/m08/bad-skill'); ((@($x.Results.Code) -contains 'SKILL_SECRET_PATTERN')) | Should Be $true }
    It 'accepts a clean skill only for manual review' { $x=& $skill (Join-Path $root 'tests/fixtures/m08/valid-skill'); $x.Passed | Should Be $true; $x.Disposition | Should Be 'manual-review-required' }
    It 'EXT-005 rejects absent integrity' { $x=& $plugin (Join-Path $root 'tests/fixtures/m08/plugin-safe') '1.2.3' 'not-integrity' 'https://registry.npmjs.org/fixture-safe/-/fixture-safe-1.2.3.tgz'; $x.Passed | Should Be $false; ((@($x.Results.Code) -contains 'INTEGRITY_REQUIRED')) | Should Be $true }
    It 'EXT-006 rejects lifecycle scripts without executing them' { $x=& $plugin (Join-Path $root 'tests/fixtures/m08/plugin-script') '1.2.3' 'sha512-ZmFrZQ==' 'https://registry.npmjs.org/fixture-script/-/fixture-script-1.2.3.tgz'; ((@($x.Results.Code) -contains 'LIFECYCLE_SCRIPT_PRESENT')) | Should Be $true }
    It 'fails closed when tarball integrity cannot be proven from an expanded directory' { $x=& $plugin (Join-Path $root 'tests/fixtures/m08/plugin-safe') '1.2.3' 'sha512-ZmFrZQ==' 'https://registry.npmjs.org/fixture-safe/-/fixture-safe-1.2.3.tgz'; $x.Passed | Should Be $false; @($x.Results.Code) -contains 'INTEGRITY_UNVERIFIABLE' | Should Be $true; $x.VmValidation | Should Be 'PENDING' }
    It 'verifies the bytes of a safe prebuilt tarball before marking it eligible' {
      $packRoot=Join-Path $TestDrive 'tgz-root';$pack=Join-Path $packRoot 'package';New-Item -ItemType Directory -Path $pack -Force|Out-Null
      [IO.File]::WriteAllText((Join-Path $pack 'package.json'),'{"name":"fixture-safe","version":"1.2.3","license":"MIT"}',(New-Object Text.UTF8Encoding($false)))
      $tgz=Join-Path $TestDrive 'fixture-safe-1.2.3.tgz';& tar.exe -czf $tgz -C $packRoot package; $LASTEXITCODE | Should Be 0
      $stream=[IO.File]::OpenRead($tgz);try{$hash=[Security.Cryptography.SHA512]::Create();try{$digest=[Convert]::ToBase64String($hash.ComputeHash($stream))}finally{$hash.Dispose()}}finally{$stream.Dispose()}
      $x=& $plugin $tgz '1.2.3' ('sha512-'+$digest) 'https://registry.npmjs.org/fixture-safe/-/fixture-safe-1.2.3.tgz';if(-not $x.Passed){throw ($x|ConvertTo-Json -Depth 8)};$x.Classification | Should Be 'simple-paid-addon-eligible';$x.VmValidation | Should Be 'PENDING'
    }
    It 'rejects a prebuilt tarball when one-byte integrity does not match' {
      $tgz=Join-Path $TestDrive 'mismatch.tgz';[IO.File]::WriteAllBytes($tgz,[byte[]](1,2,3,4))
      $x=& $plugin $tgz '1.2.3' 'sha512-ZmFrZQ==' 'https://registry.npmjs.org/fixture-safe/-/fixture-safe-1.2.3.tgz';$x.Passed | Should Be $false;@($x.Results.Code) -contains 'INTEGRITY_MISMATCH' | Should Be $true
    }
    It 'rejects an absolute or parent-relative local resource reference' {
      $s=Join-Path $TestDrive 'absolute-skill';New-Item -ItemType Directory -Path $s|Out-Null
      [IO.File]::WriteAllText((Join-Path $s 'SKILL.md'),"---`nname: absolute-skill`ndescription: test`nsource: local`nlicense: MIT`n---`n[bad](C:\Windows\win.ini)")
      $x=& $skill $s;$x.Passed | Should Be $false;@($x.Results.Code) -contains 'SKILL_RESOURCE_ESCAPE' | Should Be $true
    }
}
Describe 'M08 profile transaction' {
    It 'EXT-009 and EXT-010 restores each file from a verified backup' {
      $t=Join-Path $env:TEMP ('xq-m08-'+[guid]::NewGuid());$p=Join-Path $t 'profile';$b=Join-Path $t 'backups';New-Item -ItemType Directory -Path (Join-Path $p 'nested'),$b -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $p 'nested/a.txt'),'before');[IO.File]::WriteAllText((Join-Path $p 'b.txt'),'before2')
      $bk=& (Join-Path $root 'extensions/New-XQDSHProfileBackup.ps1') $p $b;$bk.FileCount | Should Be 2;[IO.File]::WriteAllText((Join-Path $p 'nested/a.txt'),'after');[IO.File]::WriteAllText((Join-Path $p 'extra.txt'),'extra')
      $restore=& (Join-Path $root 'extensions/Restore-XQDSHProfileBackup.ps1') -ProfilePath $p -BackupPath $bk.BackupPath -ExpectedManifestSha256 $bk.ManifestSha256 -ConfirmRestore 'RESTORE';$restore.Verification | Should Be 'PASS';[IO.File]::ReadAllText((Join-Path $p 'nested/a.txt')) | Should Be 'before';(Test-Path (Join-Path $p 'extra.txt')) | Should Be $false
      Remove-Item -LiteralPath $t -Recurse -Force
    }
    It 'refuses an overlapping backup root before creating backup files' {
      $t=Join-Path $TestDrive 'overlap';$p=Join-Path $t 'profile';$b=Join-Path $p 'backups';New-Item -ItemType Directory -Path $b -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $p 'a.txt'),'x')
      $thrown=$false;try { $null=& (Join-Path $root 'extensions/New-XQDSHProfileBackup.ps1') $p $b } catch { $thrown=$true };$thrown | Should Be $true
      @(Get-ChildItem -LiteralPath $b -Force).Count | Should Be 0
    }
    It 'refuses a changed manifest before modifying the profile' {
      $t=Join-Path $TestDrive 'tamper';$p=Join-Path $t 'profile';$b=Join-Path $t 'backups';New-Item -ItemType Directory -Path $p,$b -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $p 'a.txt'),'before')
      $bk=& (Join-Path $root 'extensions/New-XQDSHProfileBackup.ps1') $p $b;[IO.File]::AppendAllText($bk.ManifestPath,' ')
      $thrown=$false;try { $null=& (Join-Path $root 'extensions/Restore-XQDSHProfileBackup.ps1') -ProfilePath $p -BackupPath $bk.BackupPath -ExpectedManifestSha256 $bk.ManifestSha256 -ConfirmRestore 'RESTORE' } catch { $thrown=$true };$thrown | Should Be $true
      [IO.File]::ReadAllText((Join-Path $p 'a.txt')) | Should Be 'before'
    }
}

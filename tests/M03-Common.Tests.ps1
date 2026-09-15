$modulePath = Join-Path $PSScriptRoot '..\lib\XQDSH.Common.psm1'
Import-Module $modulePath -Force
function Assert-XQ { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

Describe 'M03 common safety core' {
    It 'accepts the approved Node ranges only' {
        Assert-XQ (-not (Test-XQSupportedNodeVersion '22.18.9').Passed) '22.18 must fail'
        Assert-XQ (Test-XQSupportedNodeVersion '22.19.0').Passed '22.19 must pass'
        Assert-XQ (Test-XQSupportedNodeVersion '22.99.0').Passed 'later 22.x must pass'
        Assert-XQ (Test-XQSupportedNodeVersion '24.0.0').Passed '24.x must pass'
        Assert-XQ (-not (Test-XQSupportedNodeVersion '23.0.0').Passed) '23.x must fail'
        Assert-XQ (-not (Test-XQSupportedNodeVersion '25.0.0').Passed) '25.x must fail'
    }
    It 'allows only the numeric IPv4 loopback host' {
        Assert-XQ (Test-XQLoopbackHost '127.0.0.1').Passed 'loopback must pass'
        Assert-XQ (-not (Test-XQLoopbackHost 'localhost').Passed) 'localhost must fail'
        Assert-XQ (-not (Test-XQLoopbackHost '0.0.0.0').Passed) 'wildcard must fail'
    }
    It 'redacts common canaries without blanking ordinary text' {
        $result = Protect-XQSensitiveText 'Node v22.19.0 at C:\safe; Authorization: Bearer abcdefghijkl; sk-abcdefghijkl'
        Assert-XQ ($result.Evidence.Text -match 'Node v22.19.0') 'ordinary text must remain'
        Assert-XQ ($result.Evidence.Text -notmatch 'abcdefghijkl') 'canary must be absent'
        Assert-XQ ($result.Evidence.Text -match '\[REDACTED:') 'redaction marker must exist'
    }
    It 'returns a JSON-serializable stable result shape' {
        $result = New-XQCheckResult $true 'INFO' 'TEST' 'test' @{ one = 1 }
        Assert-XQ ((@($result.PSObject.Properties.Name) -join ',') -eq 'Passed,Severity,Code,Message,Evidence') 'result shape changed'
        try { $null = $result | ConvertTo-Json -Depth 4 } catch { throw 'result must serialize as JSON' }
    }
    It 'rejects wide, Windows-descendant, UNC, and nonempty first-run paths' {
        Assert-XQ (-not (Test-XQSafeWorkspace -Path ([Environment]::GetFolderPath('MyDocuments')) -FirstRun).Passed) 'Documents root must fail'
        Assert-XQ (-not (Test-XQSafeWorkspace -Path (Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp') -FirstRun).Passed) 'Windows child must fail'
        Assert-XQ (-not (Test-XQSafeWorkspace -Path '\\server\share\workspace' -FirstRun).Passed) 'UNC path must fail'
        $nonempty = Join-Path $TestDrive 'nonempty'; New-Item -ItemType Directory -Path $nonempty | Out-Null; New-Item -ItemType File -Path (Join-Path $nonempty 'marker') | Out-Null
        Assert-XQ (-not (Test-XQSafeWorkspace -Path $nonempty -FirstRun).Passed) 'nonempty first-run workspace must fail'
    }
    It 'rejects dangerous manifest runtime fields' {
        $manifest = [pscustomobject]@{ upstream=[pscustomobject]@{packageName='@deepseek-ai/dsh';version='0.1.1-rc.2';registry='https://registry.npmjs.org/'}; runtime=[pscustomobject]@{webHost='127.0.0.1';webPort=3080;nodeRange='>=22.19.0 <23.0.0 || >=24.0.0 <25.0.0';defaultSandbox='full-access';defaultApproval='auto'}; privacy=[pscustomobject]@{xqTelemetry=$true} }
        $result = Test-XQManifestRuntimePolicy $manifest
        Assert-XQ (-not $result.Passed) 'dangerous policy must fail'
        Assert-XQ ($result.Evidence.InvalidFields -contains 'defaultSandbox') 'sandbox violation missing'
        Assert-XQ ($result.Evidence.InvalidFields -contains 'xqTelemetry') 'telemetry violation missing'
    }
    It 'redacts URL userinfo and quoted or spaced secret assignments' {
        $result = Protect-XQSensitiveText 'https://user:pass@example.test/a password = "two words" token: ''more words'''
        Assert-XQ ($result.Evidence.Text -notmatch 'user:pass|two words|more words') 'secret text remained'
    }
    It 'checks ports without terminating the owning listener' {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0; $listener.Start()
        try { $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port; $state = Get-XQPortState $port; Assert-XQ (-not $state.Passed) 'used port must be reported'; Assert-XQ ($listener.Server.IsBound) 'port listener was modified' } finally { $listener.Stop() }
    }
    It 'uses no shell string evaluation in the command helper source' {
        $source = [System.IO.File]::ReadAllText($modulePath)
        Assert-XQ ($source -notmatch 'Invoke-Expression|cmd\s+/c') 'unsafe shell evaluation found'
    }
    It 'imports on Windows PowerShell 5.1 without changing module files' {
        $before = @(Get-ChildItem -LiteralPath (Split-Path $modulePath) -File | ForEach-Object { $_.Name + ':' + $_.Length }) -join '|'
        $command = "Import-Module '" + $modulePath.Replace("'","''") + "' -Force; if ((Get-Command -Module XQDSH.Common).Count -lt 13) { exit 9 }"
        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command
        Assert-XQ ($LASTEXITCODE -eq 0) 'Windows PowerShell 5.1 could not import the module'
        $after = @(Get-ChildItem -LiteralPath (Split-Path $modulePath) -File | ForEach-Object { $_.Name + ':' + $_.Length }) -join '|'
        Assert-XQ ($before -eq $after) 'module import changed files'
    }
    It 'rejects a workspace path passing through a reparse point' {
        # A unique system-temp root avoids Pester 3 TestDrive ACL collisions on PS 5.1.
        $caseRoot = Join-Path ([IO.Path]::GetTempPath()) ('xq-reparse-' + [guid]::NewGuid().ToString('N'))
        $target = Join-Path $caseRoot 'junction-target'; $link = Join-Path $caseRoot 'junction-link'
        try {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            # New-Item -ItemType Junction is denied in some non-interactive PS 5.1
            # hosts.  mklink /J creates the same NTFS reparse point without elevation.
            $mklink = 'mklink /J "' + $link + '" "' + $target + '"'
            $previousErrorAction = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $null = & (Join-Path $env:SystemRoot 'System32\cmd.exe') /d /c $mklink 2>$null
                $mklinkExitCode = $LASTEXITCODE
            } catch { $mklinkExitCode = 1 } finally { $ErrorActionPreference = $previousErrorAction }
            if ($mklinkExitCode -eq 0 -and [IO.Directory]::Exists($link)) {
                $result = Test-XQSafeWorkspace -Path (Join-Path $link 'child') -FirstRun
                Assert-XQ (-not $result.Passed -and $result.Code -eq 'WORKSPACE_REPARSE_POINT') 'reparse point was not rejected'
            } else {
                # Application-control policies may prohibit all reparse-point creation.
                # In that host state, retain a static fail-closed contract check.
                $moduleSource = [IO.File]::ReadAllText($modulePath,[Text.Encoding]::UTF8)
                Assert-XQ ($moduleSource -match 'GetAttributes\(\$cursor\)' -and $moduleSource -match 'FileAttributes\]::ReparsePoint' -and $moduleSource -match 'WORKSPACE_REPARSE_POINT') 'reparse-point rejection contract is absent'
            }
        } finally {
            # Windows PowerShell 5.1 Remove-Item has a junction deletion bug that can
            # return Access denied.  Directory.Delete removes the reparse entry itself.
            if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link) }
            if ([IO.Directory]::Exists($caseRoot)) { [IO.Directory]::Delete($caseRoot,$true) }
        }
    }
    It 'redacts every fake canary fixture and handles long input within a bound' {
        $fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\sensitive-canaries.txt') -Raw
        $redacted = Protect-XQSensitiveText $fixture
        Assert-XQ ($redacted.Evidence.Text -notmatch 'FAKE_TEST_BEARER_NOT_REAL|FAKE_TEST_KEY_NOT_REAL|FAKE_PASSWORD|FAKE_SECRET|FAKE_SIGNATURE') 'a fake canary remained'
        $long = 'safe-prefix password="' + ('a' * 500000) + '" safe-suffix'
        $watch = [Diagnostics.Stopwatch]::StartNew(); $longResult = Protect-XQSensitiveText $long; $watch.Stop()
        Assert-XQ ($watch.Elapsed.TotalSeconds -lt 5) 'long-input redaction exceeded five seconds'
        Assert-XQ ($longResult.Evidence.Text -match 'safe-prefix' -and $longResult.Evidence.Text.Length -lt $long.Length) 'long-input redaction result is unsafe'
    }
}

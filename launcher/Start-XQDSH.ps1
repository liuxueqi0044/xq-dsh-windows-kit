[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspacePath,
    [string]$ManifestPath,
    [switch]$WhatIf,
    # This parameter exists only so automation can explicitly prove that a dry
    # run is non-interactive. It can never bypass confirmation for a real run.
    [string]$Confirm = 'true',
    [ValidateRange(15, 600)][int]$StartupTimeoutSeconds = 120
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $PSScriptRoot '..\manifest\product-manifest.json' }
Import-Module (Join-Path $PSScriptRoot '..\lib\XQDSH.Common.psm1') -Force

$script:ExitInput = 3
$script:ExitBlocked = 2
$script:ExitExternal = 4
$script:ExitInternal = 5

function Stop-XQLaunch {
    param([int]$ExitCode, [string]$Code, [string]$Message)
    Write-Output ('[{0}] {1}' -f $Code, $Message)
    exit $ExitCode
}

function ConvertTo-XQWindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append(('\' * $backslashes)); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-XQWindowsArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return [string]::Join(' ', [string[]]@($Arguments | ForEach-Object { ConvertTo-XQWindowsArgument ([string]$_) }))
}

function Test-XQSafeOverlay {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $semanticLines = @([System.IO.File]::ReadAllLines((Get-Item -LiteralPath $Path).FullName, [System.Text.Encoding]::UTF8) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart().StartsWith('#') -eq $false })
    $expectedLines = @(
        '- id: sandbox-policy',
        '  config:',
        '    mode: workspace-write',
        '    workspaceRoot: !!js process.cwd()',
        '- id: approval',
        '  config:',
        '    policy: ask',
        '- id: fs-sandbox',
        '  config:',
        '    cwd: !!js process.cwd()'
    )
    if ($semanticLines.Count -ne $expectedLines.Count) { return $false }
    for ($index = 0; $index -lt $expectedLines.Count; $index++) {
        if ($semanticLines[$index].TrimEnd() -cne $expectedLines[$index]) { return $false }
    }
    return $true
}

function Get-XQNpxRuntime {
    $node = Get-Command -Name 'node' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $npx = Get-Command -Name 'npx' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $npxCli = Join-Path (Split-Path -Parent $node.Source) 'node_modules\npm\bin\npx-cli.js'
    if (-not (Test-Path -LiteralPath $npxCli -PathType Leaf)) {
        # Keep discovery narrow: the supported Windows Node distribution places
        # npx-cli beside node.exe. We do not execute or parse an arbitrary shim.
        throw [System.IO.FileNotFoundException]::new('The supported npx-cli.js layout was not found.')
    }
    return [pscustomobject]@{ Node = $node.Source; Npx = $npx.Source; NpxCli = (Get-Item -LiteralPath $npxCli).FullName }
}

function Test-XQProcessDescendant {
    param([int]$ProcessId, [int]$AncestorProcessId)
    $seen = @{}
    for ($depth = 0; $depth -lt 24 -and $ProcessId -gt 0; $depth++) {
        if ($ProcessId -eq $AncestorProcessId) { return $true }
        if ($seen.ContainsKey($ProcessId)) { return $false }
        $seen[$ProcessId] = $true
        try {
            $record = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId={0}' -f $ProcessId) -ErrorAction Stop
            if ($null -eq $record) { return $false }
            $ProcessId = [int]$record.ParentProcessId
        } catch { return $false }
    }
    return $false
}

function Get-XQLaunchListeners {
    param([int]$Port)
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        throw [System.PlatformNotSupportedException]::new('Get-NetTCPConnection is required for listener ownership verification.')
    }
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort, OwningProcess)
}

try {
    if (-not $WhatIf -and $Confirm -notmatch '^(?i:true|1)$') {
        Stop-XQLaunch $script:ExitInput 'CONFIRM_BYPASS_REJECTED' 'A real launch cannot disable interactive confirmation. Use -WhatIf for an unattended dry run.'
    }

    $manifestRead = Read-XQProductManifest -ManifestPath $ManifestPath
    if (-not $manifestRead.Passed) { Stop-XQLaunch $script:ExitInput $manifestRead.Code 'The locked product manifest is missing or invalid.' }
    $manifest = $manifestRead.Evidence.Manifest
    $policy = Test-XQManifestRuntimePolicy -Manifest $manifest
    if (-not $policy.Passed) { Stop-XQLaunch $script:ExitInput $policy.Code 'The manifest package, registry, runtime, permission, or privacy lock is invalid.' }

    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    } catch {
        Stop-XQLaunch $script:ExitBlocked 'PLATFORM_UNKNOWN' 'Windows 11 x64 could not be verified.'
    }
    if ($operatingSystem.Caption -notmatch 'Windows 11' -or [version]$operatingSystem.Version -lt [version]'10.0.22000.0' -or
        $computer.SystemType -notmatch 'x64|64-bit') {
        Stop-XQLaunch $script:ExitBlocked 'PLATFORM_UNSUPPORTED' 'This release supports Windows 11 x64 only.'
    }

    $workspace = Test-XQSafeWorkspace -Path $WorkspacePath -FirstRun
    if (-not $workspace.Passed) { Stop-XQLaunch $script:ExitBlocked $workspace.Code $workspace.Message }
    $workspaceFull = $workspace.Evidence.Path

    # A cold npm shim on hosted Windows can take longer than eight seconds to
    # initialize. The probe is read-only and remains bounded.
    $nodeInfo = Get-XQCommandInfo -Name 'node' -Arguments @('--version') -TimeoutSeconds 30
    if (-not $nodeInfo.Passed) { Stop-XQLaunch $script:ExitBlocked 'NODE_MISSING' 'A supported Node.js installation is required.' }
    $versionMatch = [regex]::Match([string]$nodeInfo.Evidence.Output, '[vV]?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?')
    if (-not $versionMatch.Success -or -not (Test-XQSupportedNodeVersion -VersionText $versionMatch.Value -SupportedRange ([string]$manifest.runtime.nodeRange)).Passed) {
        Stop-XQLaunch $script:ExitBlocked 'NODE_VERSION_UNSUPPORTED' 'Node.js must be 22.19+ in major 22, or major 24 LTS.'
    }
    foreach ($tool in @('npm','npx')) {
        $toolInfo = Get-XQCommandInfo -Name $tool -Arguments @('--version') -TimeoutSeconds 30
        if (-not $toolInfo.Passed) { Stop-XQLaunch $script:ExitBlocked ($tool.ToUpperInvariant() + '_MISSING') ($tool + ' is required and could not be queried.') }
    }

    $portState = Get-XQPortState -Port ([int]$manifest.runtime.webPort)
    if (-not $portState.Passed) { Stop-XQLaunch $script:ExitBlocked $portState.Code 'Port 3080 is already occupied or could not be verified. No process was stopped.' }

    $overlayPath = Join-Path $PSScriptRoot 'XQ-DSH-Safe.patch.yml'
    if (-not (Test-XQSafeOverlay -Path $overlayPath)) { Stop-XQLaunch $script:ExitInput 'SAFE_OVERLAY_INVALID' 'The final workspace-write + ask overlay is missing or modified.' }
    $runtime = Get-XQNpxRuntime
    $packageSpec = '{0}@{1}' -f $manifest.upstream.packageName, $manifest.upstream.version
    $npxArguments = @(
        $runtime.NpxCli,
        '--yes',
        ('--registry={0}' -f $manifest.upstream.registry.TrimEnd('/')),
        $packageSpec,
        'web',
        '--patch', $overlayPath,
        '--host', $manifest.runtime.webHost,
        '--port', ([string]$manifest.runtime.webPort),
        '--no-open'
    )
    $logicalCommand = 'npx --yes --registry={0} {1} web --patch "{2}" --host {3} --port {4} --no-open' -f $manifest.upstream.registry.TrimEnd('/'),$packageSpec,$overlayPath,$manifest.runtime.webHost,$manifest.runtime.webPort

    Write-Output '=== XQ DSH LAUNCH PLAN ==='
    Write-Output ('Workspace: {0}' -f $workspaceFull)
    Write-Output ('Create workspace: {0}' -f (-not [System.IO.Directory]::Exists($workspaceFull)))
    Write-Output ('Network source: {0}' -f $manifest.upstream.registry)
    Write-Output ('Locked package: {0}' -f $packageSpec)
    Write-Output ('Permission: workspace-write + ask')
    Write-Output ('Telemetry: disabled for this child process')
    Write-Output ('Web address: http://127.0.0.1:3080')
    Write-Output ('Command: {0}' -f $logicalCommand)

    if ($WhatIf) {
        Write-Output '[WHATIF] PLAN ONLY: no workspace was created, no network request was made, and no process was started.'
        exit 0
    }

    Write-Output 'This will contact the official npm registry, may download package dependencies, create the workspace if absent, and start a visible foreground process.'
    $answer = Read-Host 'Type LAUNCH to continue; anything else cancels'
    if ($answer -cne 'LAUNCH') { Stop-XQLaunch $script:ExitBlocked 'USER_CANCELLED' 'Cancelled. No workspace was created, no network request was made, and no process was started.' }

    $encodedPackage = [Uri]::EscapeDataString([string]$manifest.upstream.packageName)
    $metadataUri = $manifest.upstream.registry.TrimEnd('/') + '/' + $encodedPackage + '/' + $manifest.upstream.version
    try {
        $metadata = Invoke-RestMethod -Uri $metadataUri -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
    } catch {
        Stop-XQLaunch $script:ExitExternal 'OFFICIAL_METADATA_UNAVAILABLE' 'The exact version could not be confirmed at the official npm registry. Nothing was created or started.'
    }
    if ($metadata.name -ne $manifest.upstream.packageName -or
        $metadata.version -ne $manifest.upstream.version -or
        $metadata.dist.tarball -ne $manifest.upstream.tarball -or
        $metadata.dist.integrity -ne $manifest.upstream.integrity) {
        Stop-XQLaunch $script:ExitBlocked 'UPSTREAM_LOCK_DRIFT' 'Official metadata does not match the locked package, tarball, or integrity. Nothing was created or started.'
    }

    if (-not [System.IO.Directory]::Exists($workspaceFull)) {
        [void][System.IO.Directory]::CreateDirectory($workspaceFull)
    }
    # Close the create/check race and fail if anything appeared in the directory.
    $workspaceAfterCreate = Test-XQSafeWorkspace -Path $workspaceFull -FirstRun
    if (-not $workspaceAfterCreate.Passed) { Stop-XQLaunch $script:ExitBlocked $workspaceAfterCreate.Code 'The workspace changed before launch; DSH was not started.' }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $runtime.Node
    $startInfo.Arguments = Join-XQWindowsArguments -Arguments $npxArguments
    $startInfo.WorkingDirectory = $workspaceFull
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.EnvironmentVariables['DSH_PERMISSION_MODE'] = 'workspace-write'
    $startInfo.EnvironmentVariables['DSH_TELEMETRY_DISABLED'] = '1'
    $startInfo.EnvironmentVariables['NPM_CONFIG_REGISTRY'] = $manifest.upstream.registry
    $startInfo.EnvironmentVariables['NPM_CONFIG_YES'] = 'true'

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { Stop-XQLaunch $script:ExitExternal 'PROCESS_START_FAILED' 'The visible DSH launch process could not be started.' }
    Write-Output ('Wrapper PID: {0}' -f $process.Id)

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $verifiedListeners = @()
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { break }
        $listeners = Get-XQLaunchListeners -Port ([int]$manifest.runtime.webPort)
        if ($listeners.Count -gt 0) {
            $verifiedListeners = $listeners
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if ($verifiedListeners.Count -eq 0) {
        if ($process.HasExited) {
            Stop-XQLaunch $script:ExitExternal 'DSH_BOOT_FAILED' ('DSH exited before opening the local Web UI (exit code {0}).' -f $process.ExitCode)
        }
        Write-Output '[DSH_LISTENER_TIMEOUT] The process is still visible but no listener was verified. Press Ctrl+C in this console to stop it; the launcher will not detach it.'
        $process.WaitForExit()
        exit $script:ExitExternal
    }

    $unsafe = @($verifiedListeners | Where-Object {
        $_.LocalAddress -ne '127.0.0.1' -or -not (Test-XQProcessDescendant -ProcessId ([int]$_.OwningProcess) -AncestorProcessId $process.Id)
    })
    if ($unsafe.Count -gt 0) {
        Write-Output '[UNSAFE_LISTENER] A listener was not 127.0.0.1 or did not belong to this launch process tree.'
        $verifiedListeners | ForEach-Object { Write-Output ('Listener: {0}:{1} PID {2}' -f $_.LocalAddress,$_.LocalPort,$_.OwningProcess) }
        Write-Output 'Stop the visible process with Ctrl+C now. The launcher deliberately avoids forced termination.'
        $process.WaitForExit()
        exit $script:ExitBlocked
    }

    $verifiedListeners | ForEach-Object { Write-Output ('Verified listener: {0}:{1} PID {2}' -f $_.LocalAddress,$_.LocalPort,$_.OwningProcess) }
    Write-Output 'Open manually: http://127.0.0.1:3080'
    Write-Output 'Stop normally: press Ctrl+C in this visible console.'
    $process.WaitForExit()
    $finalCode = $process.ExitCode
    $remaining = Get-XQLaunchListeners -Port ([int]$manifest.runtime.webPort)
    if ($remaining.Count -gt 0) {
        Write-Output '[ORPHAN_LISTENER] The wrapper exited but port 3080 is still listening. Review the PID above and stop it manually.'
        exit $script:ExitExternal
    }
    if ($finalCode -ne 0) { Stop-XQLaunch $script:ExitExternal 'DSH_EXITED_WITH_ERROR' ('DSH exited with code {0}.' -f $finalCode) }
    Write-Output '[DSH_EXITED] DSH stopped normally.'
    exit 0
} catch {
    # Do not echo exception text: it can contain a command line or URL supplied
    # by a lower layer. Expected failures use Stop-XQLaunch above.
    Write-Output '[LAUNCH_INTERNAL_ERROR] The launcher failed closed before it could confirm a safe result.'
    exit $script:ExitInternal
}

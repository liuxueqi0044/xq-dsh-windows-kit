[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TestPath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
    $raw = @(Invoke-Pester -Script $TestPath -PassThru -Quiet)
    $result = @($raw | Where-Object { $null -ne $_.PSObject.Properties['PassedCount'] }) | Select-Object -Last 1
    if ($null -eq $result) { throw 'Pester did not return a machine-readable summary.' }

    $summary = [ordered]@{
        PassedCount = [int]$result.PassedCount
        FailedCount = [int]$result.FailedCount
        SkippedCount = if ($null -eq $result.PSObject.Properties['SkippedCount']) { 0 } else { [int]$result.SkippedCount }
        PendingCount = if ($null -eq $result.PSObject.Properties['PendingCount']) { 0 } else { [int]$result.PendingCount }
        InconclusiveCount = if ($null -eq $result.PSObject.Properties['InconclusiveCount']) { 0 } else { [int]$result.InconclusiveCount }
        Failures = @($result.TestResult | Where-Object { $_.Result -eq 'Failed' } | ForEach-Object {
            [ordered]@{ Name = [string]$_.Name; Message = [string]$_.FailureMessage; StackTrace = [string]$_.StackTrace }
        })
    }
    $json = $summary | ConvertTo-Json -Depth 5
    $encoding = New-Object Text.UTF8Encoding($false)
    $stream = New-Object IO.FileStream($ResultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

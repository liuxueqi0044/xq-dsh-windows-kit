[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SkillPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\XQDSH.Common.psm1') -Force

function Add-XQSkillResult {
    param([System.Collections.ArrayList]$List,[bool]$Passed,[string]$Severity,[string]$Code,[string]$Message,$Evidence=$null)
    [void]$List.Add((New-XQCheckResult -Passed $Passed -Severity $Severity -Code $Code -Message $Message -Evidence $Evidence))
}

function Test-XQPathUnderRoot {
    param([string]$Root,[string]$Candidate)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    return $candidateFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)
}

$results = New-Object System.Collections.ArrayList
try {
    $root = Get-Item -LiteralPath $SkillPath -Force -ErrorAction Stop
    if (-not $root.PSIsContainer) { throw 'not-directory' }
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse-root' }
} catch {
    Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_PATH_INVALID' 'Skill directory cannot be read or is a reparse point.'
    return [pscustomobject]@{Passed=$false;Disposition='deny';Results=@($results)}
}

$name = $root.Name
if ($name -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
    Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_NAME_INVALID' 'Skill directory name must be kebab-case.' $name
}

$skillFile = Join-Path $root.FullName 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_FRONTMATTER_MISSING' 'SKILL.md is required.'
} else {
    $skillItem = Get-Item -LiteralPath $skillFile -Force
    if (($skillItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $skillItem.Length -gt 524288) {
        Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_FILE_REFUSED' 'SKILL.md is a reparse point or exceeds the review limit.'
    } else {
        $text = [IO.File]::ReadAllText($skillItem.FullName,[Text.Encoding]::UTF8)
        $frontmatter = [regex]::Match($text,'(?s)\A---\s*\r?\n(?<body>.*?)\r?\n---(?:\r?\n|\z)')
        if (-not $frontmatter.Success) {
            Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_FRONTMATTER_MISSING' 'YAML frontmatter is required.'
        } else {
            $body = $frontmatter.Groups['body'].Value
            $frontName = [regex]::Match($body,'(?m)^name:\s*["'']?(?<value>[a-z0-9-]+)["'']?\s*$')
            $description = [regex]::Match($body,'(?m)^description:\s*(?<value>\S.*)$')
            $source = [regex]::Match($body,'(?m)^source:\s*(?<value>\S.*)$')
            $license = [regex]::Match($body,'(?m)^license:\s*(?<value>\S.*)$')
            if (-not $frontName.Success -or $frontName.Groups['value'].Value -ne $name) { Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_NAME_MISMATCH' 'Frontmatter name must equal the directory name.' }
            if (-not $description.Success) { Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_DESCRIPTION_MISSING' 'Frontmatter description is required.' }
            if (-not $source.Success) { Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_SOURCE_UNKNOWN' 'Frontmatter source is required.' }
            if (-not $license.Success) { Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_LICENSE_UNKNOWN' 'Frontmatter license is required.' }
        }

        $references = New-Object System.Collections.Generic.List[string]
        foreach ($match in [regex]::Matches($text,'(?i)(?<path>(?:resources?|references)[\\/][^\s\)\]"''<>]+)')) {
            [void]$references.Add($match.Groups['path'].Value.TrimEnd('.',','))
        }
        foreach ($destination in [regex]::Matches($text,'(?m)\[[^\]]*\]\((?<path>[^\)]+)\)')) {
            $value = $destination.Groups['path'].Value.Trim(' ','"','''')
            if ($value -match '^[A-Za-z]:[\\/]' -or $value -match '^[\\/]{2}') { [void]$references.Add($value) }
            elseif ($value -notmatch '^[a-z][a-z0-9+.-]*:' -and $value -notmatch '^#') { [void]$references.Add($value) }
        }
        foreach ($reference in @($references | Select-Object -Unique)) {
            $normalized = $reference -replace '/',[IO.Path]::DirectorySeparatorChar
            $unsafe = [IO.Path]::IsPathRooted($normalized) -or $normalized -match '(^|[\\/])\.\.([\\/]|$)' -or $normalized -match '^[\\/]{2}'
            if ($unsafe) {
                Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_RESOURCE_ESCAPE' 'A resource reference escapes the skill root.' $reference
                continue
            }
            try { $candidate = [IO.Path]::GetFullPath((Join-Path $root.FullName $normalized)) } catch { $candidate = $null }
            if ($null -eq $candidate -or -not (Test-XQPathUnderRoot $root.FullName $candidate) -or -not (Test-Path -LiteralPath $candidate)) {
                Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_RESOURCE_MISSING' 'A referenced resource is missing or outside the skill root.' $reference
                continue
            }
            $candidateItem = Get-Item -LiteralPath $candidate -Force
            if (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_RESOURCE_REPARSE_POINT' 'Referenced reparse points are not eligible.' $reference
            }
        }

        if ($text -match '(?i)\b(sk-[A-Za-z0-9_-]{8,}|authorization\s*:\s*bearer|password\s*[:=]|token\s*[:=])') { Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_SECRET_PATTERN' 'Recognized secret pattern found.' }
        if ($text -match '(?i)(invoke-expression|\biex\b|downloadstring|curl\s+.*\|\s*(?:sh|bash)|disable.*(?:defender|firewall)|remove-item\s+-recurse)') { Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_DANGEROUS_INSTRUCTION' 'Recognized dangerous instruction found.' }
        if ($text -match '(?i)(upload|exfiltrat|send.*https?://|webhook)') { Add-XQSkillResult $results $false 'BLOCKER' 'SKILL_UPLOAD_BEHAVIOR' 'Network upload behavior requires manual rejection.' }
    }
}

if (@($results).Count -eq 0) { Add-XQSkillResult $results $true 'INFO' 'SKILL_STATIC_CHECKS_PASSED' 'Static checks passed; operator review remains required.' }
$passed = @($results | Where-Object {-not $_.Passed}).Count -eq 0
[pscustomobject]@{Passed=$passed;Disposition=$(if($passed){'manual-review-required'}else{'deny'});Results=@($results)}

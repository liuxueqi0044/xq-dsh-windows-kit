[CmdletBinding()]
param([string]$Root, [switch]$RequireComplete, [switch]$AsLibrary)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Id,[string]$Status,[string]$Message) { [void]$results.Add([pscustomobject]@{Id=$Id;Status=$Status;Message=$Message}) }
$content = Join-Path $Root 'content'
$expected = @('00-开始这里.html','01-环境检查/使用说明.html','02-启动工具/启动与停止.html','03-配置指南/01-配置DeepSeek模型.html','03-配置指南/02-创建安全工作区.html','03-配置指南/03-跑通第一次任务.html','03-配置指南/04-权限与审批.html','03-配置指南/05-更新备份与回滚.html','03-配置指南/06-常见问题.html','04-诊断工具/诊断工具说明.html','05-Skill与插件说明/Skill安装范围.html','05-Skill与插件说明/插件安装风险.html','05-Skill与插件说明/每个加5元服务边界.html','07-售后范围/自助版.html','07-售后范围/远程版.html','07-售后范围/提交问题前请准备.html')
$all = @($expected | ForEach-Object { Join-Path $content $_ })
$missing = @($all | Where-Object { -not (Test-Path -LiteralPath $_) })
Add-Result 'DOC-001' $(if($missing.Count -eq 0){'PASS'}else{'FAIL'}) $(if($missing.Count -eq 0){'All required offline pages exist'}else{"Missing: $($missing -join ', ')"})
$scan = Join-Path $PSScriptRoot 'Scan-M07OfflineContent.ps1'
try { $scanResult = & $scan -Root $Root; Add-Result 'DOC-002' $(if($scanResult.Passed){'PASS'}else{'FAIL'}) 'Offline pages and relative navigation scan completed'; Add-Result 'DOC-003' $(if($scanResult.Passed){'PASS'}else{'FAIL'}) 'No remote resources, scripts, forms, tracking, or broken links' } catch { Add-Result 'DOC-002' 'FAIL' $_.Exception.Message; Add-Result 'DOC-003' 'FAIL' $_.Exception.Message }
$joined = (($all | Where-Object {Test-Path $_} | ForEach-Object {[IO.File]::ReadAllText($_,[Text.Encoding]::UTF8)}) -join "`n")
Add-Result 'DOC-004' $(if($joined -notmatch '(?i)(DeepSeek\s+(?:官方\s+)?Logo|官方安装器|官方 Agent)'){'PASS'}else{'FAIL'}) 'No logo or misleading official-brand claim'
Add-Result 'DOC-005' $(if(($joined -match '不是 DeepSeek 官方或授权代理') -and ($joined -match '开发者预览')){'PASS'}else{'FAIL'}) 'Non-official and preview-risk statements are visible'
Add-Result 'DOC-006' $(if(($joined -match '0\.1\.1-rc\.2') -and ($joined -match '22\.19') -and ($joined -match '24') -and ($joined -match '127\.0\.0\.1:3080') -and ($joined -match 'workspace-write') -and ($joined -match 'ask')){'PASS'}else{'FAIL'}) 'Runtime facts match locked manifest'
Add-Result 'DOC-007' $(if(($joined -match '¥12\.9') -and ($joined -match '¥39\.9') -and ($joined -match '\+¥5') -and ($joined -match '不包含')){'PASS'}else{'FAIL'}) 'Service tiers and +¥5 boundary are stated'
Add-Result 'DOC-008' $(if(($joined -match '用户本人.*输入 Key') -and ($joined -match '不能.*发送.*客服')){'PASS'}else{'FAIL'}) 'User-entered Key and no-support-sharing rule stated'
Add-Result 'DOC-009' $(if(($joined -match 'hello\.txt') -and ($joined -match '禁止删除') -and ($joined -match '凭据')){'PASS'}else{'FAIL'}) 'First task is low-risk read/write only'
Add-Result 'DOC-010' $(if(($joined -match '停止') -and ($joined -match '备份') -and ($joined -match '回滚') -and ($joined -match '卸载')){'PASS'}else{'FAIL'}) 'Stop, backup, uninstall, and rollback guidance exists'
Add-Result 'DOC-011' $(if(($joined -match 'draft') -and ($joined -match '开发者预览') -and ($joined -match '限制')){'PASS'}else{'FAIL'}) 'Known limits and draft/preview status are stated'
Add-Result 'DOC-012' 'PENDING' '中文 Windows 11 x64 VM visual acceptance is pending'
$results
$blocking = @($results | Where-Object {$_.Status -eq 'FAIL'}).Count -gt 0
if ($RequireComplete -and @($results | Where-Object {$_.Status -eq 'PENDING'}).Count -gt 0) {$blocking = $true}
$underPester = $null -ne (Get-Command Describe -ErrorAction SilentlyContinue)
if ((-not $AsLibrary) -and $blocking -and -not $underPester) { exit 1 }

# Pester 3.4 discovery contract: the harness above also remains runnable in CI without Pester.
if ($underPester) {
  Describe 'M07 offline Chinese content' {
    It 'has every required page (DOC-001)' { @($missing).Count | Should Be 0 }
    It 'passes the offline security and navigation scan (DOC-002/DOC-003)' { $scanResult.Passed | Should Be $true }
    It 'states locked runtime and service boundaries (DOC-006/DOC-007)' { ($joined -match '0\.1\.1-rc\.2') -and ($joined -match '¥12\.9') -and ($joined -match '\+¥5') | Should Be $true }
    It 'protects keys and constrains first task (DOC-008/DOC-009)' { ($joined -match '用户本人.*输入 Key') -and ($joined -match '不能.*发送.*客服') -and ($joined -match 'hello\.txt') | Should Be $true }
    It 'documents lifecycle and preview status (DOC-010/DOC-011)' { ($joined -match '回滚') -and ($joined -match 'draft') -and ($joined -match '开发者预览') | Should Be $true }
  }
}

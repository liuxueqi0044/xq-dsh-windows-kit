# Changelog

## Unreleased — M06–M11 implementation baseline

- 完成只读诊断与二次脱敏实现及自动化覆盖。
- 完成断网中文指南、品牌声明、服务边界和安全工作区说明。
- 完成 Skill/插件静态审核与 Profile 事务测试。
- 完成白名单构建、离线内容扫描、稳定 ZIP 与 hash 报告。
- 完成 PowerShell 5.1/7、Pester 3.4 的测试编排和 Validate/Candidate CI 合同。
- PowerShell 源统一为 UTF-8 BOM，并隔离每个 Pester 3.4 测试进程，消除 PS5.1 中文解析和跨套件状态污染。
- 完成 M11 中英文 Windows 11 VM 测试计划与双人证据规则。

仍未宣称完成：M04/M05 真实 DSH、DIA-014、DOC-012、M08 真实扩展生命周期、M10 GitHub main 绿色 run、M11 中英文 VM 和双人复核。当前版本是开发基线，不是可发布商品。

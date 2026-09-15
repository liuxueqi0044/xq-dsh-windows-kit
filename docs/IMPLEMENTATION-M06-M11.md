# M06–M11 实施收尾

截至本记录，M06–M11 的源码与本地自动化实现已完成，测试和发布状态仍以实际证据为准。实现遵循冻结的 manifest、治理 JSON、公共 PowerShell 安全内核和 M11 人工门禁合同；没有自动修改生产安全默认值，也没有把人工验收写成通过。

| 模块 | 已实现 | 当前 PENDING |
|---|---|---|
| M06 | 只读诊断、字段级/序列化后二次脱敏、Schema 与 canary 测试 | DIA-014 人工抽查 |
| M07 | 16 个断网中文 HTML、统一内联 CSS、相对导航、服务与风险边界 | DOC-012 中文 Windows VM 视觉 |
| M08 | Skill/插件静态审核、默认拒绝、Profile 备份/回滚/删除测试 | 真实扩展生命周期 |
| M09 | 白名单渲染、敏感扫描、稳定 ZIP、内外 hash、构建报告 | 候选制品证据 |
| M10 | PS5.1/7 编排、Pester 3.4、Validate/Candidate 工作流、独立 prebuild gate | GitHub main 实际绿色 run |
| M11 | VM 证据模型、VM-001…014 计划、发布判定与双人复核合同 | 中英文 VM、E2E 与双人复核 |

## 测试与发布边界

Validate 只运行本地静态、单元、契约和开发构建测试，不运行在线 resolver 或候选构建。Candidate 仅手动触发：先跑 M01–M10，再核验官方在线 observation，生成 `xq.m10.prebuild-gate.v1`，通过后构建并验证候选 ZIP。M11、DIA-014、DOC-012 和真实扩展操作必须由隔离 VM/人工完成。

当前结论：这是开发基线，不是可发布商品。任何 FAIL、PENDING、skipped、证据缺失或 hash 不一致都保持 `draft`/`candidate`。

## 多智能体分工与总架构复核

- Terra 诊断执行单元：M06 诊断与 M09 白名单打包。
- Luna 内容执行单元：M07 离线中文内容、M10 测试/CI 编排及文档收尾。
- Terra 扩展执行单元：M08 Skill/插件边界与 M11 证据门禁。
- Sol 主架构与集成：统一模块合同，复核并加固 tar/SRI、路径和 reparse 防护、事务备份/恢复、候选 prebuild gate、证据一致性、PowerShell 5.1 编码和 Pester 隔离，最后生成并核验开发制品。

执行智能体的产出不直接视为验收通过；所有模块均由主架构层重新阅读、负向测试和跨版本集成。DOC-012 尝试使用本地浏览器做视觉检查时，浏览器安全策略拒绝 `file://` 页面，因此没有用替代证据冒充真实中文 Windows VM 视觉验收。

## 本地验收结果

| 检查 | 结果 |
|---|---|
| Windows PowerShell 5.1 `Invoke-Tests.ps1 -Mode Validate` | 10/10 门禁项 PASS，0 失败 |
| PowerShell 7 `Invoke-Tests.ps1 -Mode Validate` | 10/10 门禁项 PASS，0 失败 |
| 统一门禁中的 Pester | 59 项 PASS，0 failed/skipped/pending/inconclusive |
| M11 证据门禁专项 | 6 项 PASS；诚实 PENDING 模板有效但不完整；`-RequireComplete` 退出码 2 |
| JSON Schema | 8 个 JSON 实例与 2 个 Schema 合同通过 |
| 开发制品 | 目录与 ZIP 均为 30 个文件；29 个内部 hash 全部匹配；PowerShell 解析错误 0 |
| 打包脚本烟雾测试 | 环境检查退出 0；启动器 `-WhatIf` 退出 0 且未创建工作区；诊断报告写入/解析通过 |

PowerShell 文件统一使用 UTF-8 BOM，以保证 Windows PowerShell 5.1 正确解析中文路径和断言。Pester 3.4 的每个测试文件由独立 PowerShell 进程执行，避免 Mock/TestDrive 状态跨套件污染；缺失、skipped、pending 或 inconclusive 仍按失败处理。

## 开发制品

- 目录：`dist/XQ-DSH-Windows-v1.0.0/`
- ZIP：`dist/XQ-DSH-Windows-v1.0.0.zip`
- ZIP SHA-256：`6e22bc753022ab573b2549361d48c9f1b23e88db874b243de35e707a5b8ba5fc`（47,057 bytes）
- 状态：`buildKind=development`、`productReleaseState=draft`、`m11=PENDING`

该 ZIP 仅用于开发审阅。未执行 Candidate 网络重验，也没有 GitHub main run、中英文 VM 或双人签字，因此不得改名为正式包或发布候选。

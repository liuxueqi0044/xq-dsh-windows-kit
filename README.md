# xq-dsh-windows-kit

状态：**M01–M11 源码与本地自动化实现基线已完成；开发基线，不是可发布商品。**

本仓库提供兼容 DeepSeek Harness 0.1.1-rc.2 的 Windows 11 x64 中文配置、只读诊断、离线指南、扩展审核、白名单构建和测试编排。XQ效率工具不是 DeepSeek 官方或授权代理。DSH 仍为开发者预览版，Windows 沙箱是部分限制，不能宣称绝对隔离或已完成安全审计。

当前仍为 `PENDING`：M04/M05 真实 DSH 环境与启动、DIA-014 人工抽查、DOC-012 中文 VM 视觉验收、M08 真实扩展生命周期、M10 GitHub main 实际绿色 run、M11 中英文 Windows VM 与双人复核。没有这些证据不得标记 releasable、开发完成或可上架。

本地已生成 `dist/XQ-DSH-Windows-v1.0.0.zip` 开发制品（`draft`，不是候选发布），SHA-256：`6e22bc753022ab573b2549361d48c9f1b23e88db874b243de35e707a5b8ba5fc`。

入口：`docs/ARCHITECTURE.md`、`docs/SECURITY-BOUNDARIES.md`、`docs/IMPLEMENTATION-M06-M11.md`、`acceptance/ACCEPTANCE-MATRIX.md`、`acceptance/VM-TEST-PLAN.md`、`tests/Invoke-Tests.ps1`。

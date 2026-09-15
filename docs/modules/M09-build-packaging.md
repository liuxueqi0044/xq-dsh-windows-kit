# M09 构建、扫描与打包

## 目标

从经验证源码生成任务书规定的商品目录和候选 ZIP，保证只有白名单文件进入制品，并产生独立 hash 和发布清单。

## 输入

- M01 有效清单；
- M02 供应链验证结果；
- M03–M07 通过模块验收的文件；
- 明确的 `build/package-layout.json` 白名单映射。

M08、测试夹具、源码日志、下载 staging 和 VM 证据不进入自助 ZIP。

## 依赖与非职责

依赖 M01、M02 和 M03–M07 的候选输出。M09 不决定测试是否通过；M10 的候选工作流负责在构建前后编排测试。M09 不改变 releaseState，也不从仓库外随意抓取文件。

## 输出

- `build/Render-OfflineContent.ps1`；
- `build/Build-Package.ps1`；
- `dist/XQ-DSH-Windows-v1.0.0/`；
- `dist/XQ-DSH-Windows-v1.0.0.zip`；
- 与 ZIP 并列的 `release-manifest.json`、`SHA256SUMS.txt` 和构建报告。

## 构建顺序

1. 清单/Schema/政策验证；
2. 供应链在线复核；
3. 接收 M10 预构建门禁已通过的机器可读结果；直接调用只能生成开发制品，不能声称候选通过；
4. 新建干净 staging；
5. 按白名单复制并映射中文目录；
6. 复制已验证 LICENSE 和来源清单；
7. HTML 离线扫描；
8. 敏感文件名、内容和 ZIP entry 扫描；
9. 生成内部 SHA256SUMS；
10. 按稳定路径顺序创建 ZIP；
11. 从 ZIP 重新扫描；
12. 生成外部 release manifest。

构建默认拒绝覆盖已有正式制品；候选输出使用新的 staging。ZIP 时间戳和路径顺序应固定，以支持同一工具链下的可重复构建。

内部 `SHA256SUMS.txt` 列出除自身之外的包内文件；外部 release manifest 记录 ZIP hash，避免任何自引用。

## 失败模式

任一输入门禁、白名单、扫描、hash 或 ZIP 复检失败时删除本次临时 staging，并不发布目标文件。清理只能针对已经验证位于构建临时根下的路径。

## 验收标准

- `BLD-001`：输出目录与任务书目录结构逐项一致。
- `BLD-002`：仅 package layout 白名单文件进入 ZIP。
- `BLD-003`：M08 操作员工具、tests、staging、cache、node_modules 不进入 ZIP。
- `BLD-004`：供应链或自动化测试失败时不生成候选 ZIP。
- `BLD-005`：HTML 外链和远程资源扫描失败会阻断构建。
- `BLD-006`：`.env`、Key、Token、Cookie、会话和工作区夹具会阻断构建。
- `BLD-007`：ZIP entry 不含绝对路径、`..` 或路径逃逸。
- `BLD-008`：内部文件 hash 与解压后文件一致。
- `BLD-009`：外部 release manifest 的 ZIP SHA-256 与实际一致。
- `BLD-010`：ZIP 不包含自引用 ZIP hash。
- `BLD-011`：同一固定工具链和相同输入的两次构建 hash 一致。
- `BLD-012`：未完成 M11 时 README 和 manifest 保持 draft/candidate，不写 releasable。
- `BLD-013`：最终制品在断网环境可打开全部指南和脚本说明。
- `BLD-014`：构建报告记录工具版本、输入 commit 和各门禁状态。

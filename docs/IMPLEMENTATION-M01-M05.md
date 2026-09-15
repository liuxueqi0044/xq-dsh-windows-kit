# M01–M05 实现与验收记录

状态：`IMPLEMENTATION-CANDIDATE`
日期：2026-08-29
结论：前五个模块的源码与安全负向自动化已完成；这不等于商品发布完成。

## 1. 多智能体分工

| 角色 | 模型 | 工作 | Sol 复核 |
|---|---|---|---|
| Supply-chain 员工 | Terra | M01、M02 初始实现与三轮修正 | 深层未知字段、精确 URI/hash 信任根、错误分类、真实 tar 行为 |
| Runtime 员工 | Terra | M03、M04 实现与负向补测 | 危险策略、UNC/reparse、脱敏、PS 5.1、只读边界 |
| QA 员工 | Luna | M01–M05 夹具和零副作用启动测试 | 去除假阳性、入口行为、WhatIf、取消和非空路径 |
| 总架构师/集成人 | Sol | 总体架构、上游源码核验、M05、集成与最终判定 | 全部高风险文件逐行复核并重跑测试 |

员工报告不能直接改变验收状态；本记录中的状态以 Sol 重跑结果为准。

## 2. 模块交付

### M01 治理、Schema 与 Manifest

- 精确锁定 `@deepseek-ai/dsh@0.1.1-rc.2`、官方 registry、tarball、SRI、SHA-256、Git tag/commit 和 LICENSE hash；
- 运行、隐私、支持范围、扩展服务和发布门禁均使用关闭未知字段的 JSON；
- `build/Test-Governance.ps1` 在 Windows PowerShell 5.1 下执行 fail-closed 深层校验；
- `releasable` 必须同时具有四项 gate evidence 与人工批准引用。

### M02 官方上游供应链

- 只观察精确版本端点；`latest`/`next` 只记录，绝不参与选择；
- registry、tarball、Git 仓库和 raw LICENSE 使用精确关系锁，不以宽泛 hostname 代替；
- 下载后验证 SRI、SHA-256、包内 name/version/repository/license/bin、tag commit 和 LICENSE hash；
- tar 仅列出/读取允许的元数据，拒绝绝对路径与 `..`；不运行 npm lifecycle 或包内 JS；
- 明确记录 npm `gitHead`/provenance 为 `UNAVAILABLE`，并保留传递依赖范围风险。

### M03 PowerShell 公共安全内核

- 提供统一结果对象、严格 manifest 运行锁、Node 版本、loopback、端口、路径、命令超时和脱敏接口；
- 拒绝磁盘根、用户/桌面/文档/下载根、Windows 后代、UNC、非空首次目录和 reparse point；
- 外部只读命令使用参数数组语义和并发输出排空，不使用脚本字符串求值；
- PowerShell 5.1 与 7 均已导入验证。

### M04 只读环境检查器

- 检查 Windows 11 x64、管理员状态、Node/npm/npx/pnpm、3080、DSH、npm cache 元数据、DSH Home、工作区和磁盘空间；
- 不访问网络，不安装/修复，不修改 PATH 或 ExecutionPolicy，不创建工作区，不结束进程；
- 支持 Human/Json 输出与稳定退出码。

### M05 受控启动器

- 必填窄工作区；无默认用户目录、host/port/package/registry/权限覆盖或无人值守确认绕过；
- `-WhatIf` 在确认和网络之前返回，零创建、零下载、零启动；
- 用户必须精确输入 `LAUNCH`，随后才查询官方精确元数据和创建工作区；
- 使用官方精确包、显式 registry、`127.0.0.1:3080` 和 `--no-open`；
- 最终 overlay 在用户 Profile/Home 之后强制 `workspace-write + ask`、文件系统 cwd，并通过精确语义行校验；
- 仅向子进程设置 `DSH_PERMISSION_MODE=workspace-write`、`DSH_TELEMETRY_DISABLED=1` 和官方 npm registry；
- 直接使用 `node.exe + npx-cli.js`，不经过命令 shell；控制台可见、不注册服务/任务/防火墙/持久化；
- 启动后要求监听为 `127.0.0.1:3080`，且监听 PID 属于本次 wrapper 进程树；失败时不静默报告成功。

## 3. 已执行证据

| 验证 | 结果 |
|---|---|
| Windows PowerShell 5.1 `Test-Governance.ps1` | PASS |
| Draft 2020-12 JSON Schema 实际验证 | 5/5 PASS |
| M01 Pester | 7/7 PASS |
| M02 Pester（含真实官方 tarball、改单字节、真实 `../` tar） | 6/6 PASS |
| M02 官方在线 resolver | PASS；candidate 存在；9 项 checks 全 true |
| M03 Pester | 12/12 PASS |
| M04 Pester | 6/6 PASS |
| M05 安全行为驱动 | 6/6 PASS |
| M05 Windows PowerShell 5.1 默认 manifest `-WhatIf` | PASS |

主要命令：

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\build\Test-Governance.ps1
python .\tests\Validate-JsonSchemas.py
pwsh -NoProfile -Command "Invoke-Pester -Script .\tests\M01-Governance.Tests.ps1"
pwsh -NoProfile -Command "Invoke-Pester -Script .\tests\M02-SupplyChain.Tests.ps1"
pwsh -NoProfile -Command "Invoke-Pester -Script .\tests\M03-Common.Tests.ps1"
pwsh -NoProfile -Command "Invoke-Pester -Script .\tests\M04-Environment.Tests.ps1"
pwsh -NoProfile -File .\tests\M05-Launcher.Tests.ps1
pwsh -NoProfile -File .\tests\Invoke-M01-M05Tests.ps1
```

## 4. 保持 PENDING 的外部门禁

- Windows 10、非 x64、低磁盘空间等隔离场景；
- 在干净 Windows 11 VM 中真实执行 npx 下载与首次启动；
- 实际 resolved config、`workspace-write + ask` 和 telemetry disable 的运行时证据；
- 实际 listener PID/进程树、正常 Ctrl+C 停止和 boot/network/端口失败矩阵；
- 中文/英文 VM、真实测试账号和一次受控 Agent 任务；
- M06–M11、GitHub Actions、候选 ZIP 与发布签字。

这些项目没有被本机单元测试替代，因此 M04/M05 整体和商品发布状态仍为 `PENDING`。

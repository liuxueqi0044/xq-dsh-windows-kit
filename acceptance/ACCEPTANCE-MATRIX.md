# XQ DSH Windows Kit 验收矩阵

状态：`M06-M11-IMPLEMENTATION-COMPLETE-PENDING-EVIDENCE`

`PASS` 必须有实际证据；`FAIL`、`PENDING` 或 skipped 的必需项均阻止开发完成和发布。自动化不能替代人工 VM、真实 DSH、GitHub main 或双人复核。

| 模块 | 验收 ID | 当前状态 | 证据/残余 PENDING |
|---|---|---|---|
| M01 | GOV-001…012 | PASS | 治理校验与 Pester |
| M02 | SUP-001…015 | PASS/候选重跑 | 在线 observation 需候选证据 |
| M03 | CORE-001…012 | PASS | PS5.1/7 自动化 |
| M04 | ENV-001…014 | 本地 PASS / 整体 PENDING | M04 真实 DSH 环境与 Windows 集成 |
| M05 | RUN-001…016 | 本地 PASS / 整体 PENDING | 真实 DSH 启动、监听与进程树 |
| M06 | DIA-001…015 | 自动 PASS / 整体 PENDING | DIA-014 人工抽查 |
| M07 | DOC-001…012 | 静态 PASS / 整体 PENDING | DOC-012 中文 Windows VM 视觉验收 |
| M08 | EXT-001…014 | 自动 PASS / 整体 PENDING | 真实 Skill/插件生命周期 |
| M09 | BLD-001…014 | 开发构建 PASS / 候选 PENDING | 候选 ZIP、hash 与构建证据 |
| M10 | TST-001…016 | 本地 Validate PASS / 整体 PENDING | GitHub main 实际绿色 run URL/ID |
| M11 | VM-001…014、REL-001…004 | PENDING | 中英文 VM 与双人复核 |

## 自动化场景映射

| 场景 | 验收 ID |
|---|---|
| latest、错误包名/registry、alpha | GOV-003…005、SUP-010、TST-002 |
| integrity/SHA/commit/LICENSE | SUP-003…009、TST-003 |
| host、危险权限、宽目录、路径逃逸 | CORE-004、CORE-007、RUN-005/007/008、TST-004/005 |
| HTML 外链、脚本、统计、敏感 ZIP | DOC-003、BLD-005/006、TST-006/007 |
| 诊断脱敏与失败退出 | DIA-008/009、ENV-004、RUN-011、TST-008/009 |
| Skill/插件静态边界 | EXT-001…008、TST-010/011 |
| Profile 备份、回滚、删除 | EXT-009…012、TST-012 |
| PS5.1/7、跳过阻断、生产默认不变 | TST-013…016 |

## 发布门禁

只有 M01–M10 自动化、M04/M05 真实流程、中文/英文 VM、扩展全生命周期、main 绿色 run、候选 ZIP/hash、DIA-014 和双人复核全部有证据，才可由人工建议 `releasable`。当前任何缺证据项均保持 `draft`/`candidate`。

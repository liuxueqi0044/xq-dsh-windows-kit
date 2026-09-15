# M08 Skill/插件审核与事务化服务

## 目标

为 +¥5 服务建立可审计、可回滚的操作员流程，同时与自助产品隔离。该模块不是通用插件安装器。

## 输出

- `extensions/Test-XQDSHSkill.ps1`：只读 Skill 审核；
- `extensions/Test-XQDSHPluginPackage.ps1`：只读 npm 包审核；
- Profile 备份、安装验证、回滚和删除的操作员脚本或明确 SOP；
- 安装记录 Schema；
- 无敏感数据的测试 Skill 和预构建测试插件夹具。

以上可执行工具不进入 ¥12.9 自助 ZIP。

## 输入、依赖与非职责

依赖 M01 的服务政策、M02 的兼容性证据和 M03 的路径/脱敏能力。该模块不承诺发现全部恶意行为，不为超范围插件自动放宽规则，也不处理用户账号、OAuth 或付费服务配置。

## Skill 架构

检查目录名/frontmatter `name` 的 kebab-case、一致性、description、引用资源存在性、路径逃逸、秘密模式、危险指令、上传行为、来源和许可证。自动检查只能给出风险信号，最终仍需人工阅读。

安装目标按用户意图选择项目 `.agents/skills`、项目 `.dsh/skills` 或经确认的用户级目录。路径必须由系统 API 解析，不硬编码用户名。

## 插件分类

只有精确版本、来源明确、预构建、根包及可解析依赖闭包无未知 lifecycle script、无管理员权限、无公网监听、无后台服务、无 OAuth/付费账号、无 `allowBuilds`、与锁定 DSH 有兼容证据的包才能标记 `simple-paid-addon-eligible`。无法可靠检查依赖闭包时默认不合格。

Git 源、`prepare`、原生二进制、浏览器驱动和复杂外部服务直接分类为 `out-of-scope`，不得通过警告后继续按 ¥5 安装。

## Profile 事务

备份包含文件清单与 SHA-256。安装前显示包、版本、来源、新增权限和外部服务并获得确认。安装后依次进行 dump-config、boot、最小功能、监听范围检查。失败时恢复备份并再次 dump-config。

## 失败模式

任何静态审核未知项均保持不合格；备份不完整时禁止安装；安装后任一验证失败即进入回滚。回滚失败是最高级别人工介入状态，不能继续安装其他扩展。

## 验收标准

- `EXT-001`：非法 Skill 名、缺 frontmatter、name 不一致被拒绝。
- `EXT-002`：绝对路径、`..`、不存在资源和路径逃逸被拒绝。
- `EXT-003`：秘密和明显危险指令产生阻断项。
- `EXT-004`：安装后和删除后 catalog 行为在 VM 中验证。
- `EXT-005`：插件没有精确版本或 integrity 时不合格。
- `EXT-006`：未知 preinstall/install/postinstall/prepare 脚本不合格。
- `EXT-007`：Git 源、原生构建或 `allowBuilds` 不合格。
- `EXT-008`：需要管理员、公网监听、后台服务、OAuth 或付费 API 不合格。
- `EXT-009`：Profile 变更前备份和 hash 完成。
- `EXT-010`：安装失败能恢复逐文件一致的备份。
- `EXT-011`：安装后 dump-config、boot、功能和监听检查全部通过才登记成功。
- `EXT-012`：删除后插件消失、Profile 正常、监听未扩大。
- `EXT-013`：安装记录不含 Key、Token、Cookie 或用户文件内容。
- `EXT-014`：操作员工具未进入自助 ZIP。

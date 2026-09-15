# M01 治理、Schema 与 Manifest

## 目标

建立全项目唯一的产品事实与政策来源，防止启动器、诊断器、构建脚本和文档各自硬编码不同规则。

## 输入

- 已人工选定的产品版本和 DSH 候选版本；
- 官方 npm/GitHub 证据；
- 产品支持范围、安全边界和服务条款；
- M11 的发布门禁定义。

## 输出

- `manifest/product-manifest.json`；
- `manifest/trusted-sources.json`；
- `governance/product-scope.json`；
- `governance/support-matrix.json`；
- `governance/extension-service-policy.json`；
- 对应的 `schemas/*.schema.json`。

## 依赖与非职责

本模块由 Sol 的产品决策和 M02 的官方观察提供事实输入。它不访问网络、不下载包、不启动 DSH，也不根据当前 `latest` 自动改变候选版本。

## 详细设计

`product-manifest.json` 分为五组字段：

1. `product`：名称、版本、品牌声明版本；
2. `upstream`：包、版本、registry、tarball、SRI、SHA-256、tag、commit、LICENSE；
3. `runtime`：OS、架构、Node 范围、host、port、sandbox、approval；
4. `privacy`：XQ telemetry、诊断上传和会话上传默认值；
5. `release`：状态、锁定时间、所需门禁和人工签字引用。

Schema 必须关闭未知属性，hash 使用固定长度小写十六进制，SRI 使用 `sha512-` 前缀，版本不允许 `latest`/`next`。运行字段不得被命令行覆盖。

`trusted-sources.json` 只允许 HTTPS，明确 npm host、GitHub host、raw content host和仓库路径。重定向目标必须重新过白名单。

治理 JSON 使用枚举表达支持与不支持项，不能依赖营销文本解释安全行为。

## 接口

M03 暴露 `Read-XQProductManifest` 和 `Test-XQRuntimePolicy`。M02 只比较观察值，不自动改锁。M09 在构建前执行全部 Schema 验证。

## 失败模式

- 缺字段、未知字段或类型错误：退出码 3；
- 浮动版本、非官方 registry、危险默认权限：策略失败；
- hash 格式正确但证据不匹配：由 M02 退出码 2；
- `releaseState=releasable` 但缺证据引用：Schema/发布门禁失败。

## 验收标准

- `GOV-001`：所有 JSON 能通过其 Schema。
- `GOV-002`：Schema 拒绝未知顶层和安全相关字段。
- `GOV-003`：拒绝 `latest`、`next`、范围版本和空版本。
- `GOV-004`：拒绝非 `@deepseek-ai/dsh` 包名。
- `GOV-005`：拒绝非官方 npm registry 或非 HTTPS URL。
- `GOV-006`：拒绝非 `127.0.0.1` host。
- `GOV-007`：拒绝 `danger-full-access` 或 `approval=never`。
- `GOV-008`：支持范围只包含 Windows 11 x64 和批准的 Node 范围。
- `GOV-009`：`xqTelemetry` 与诊断上传均为 false。
- `GOV-010`：alpha 版本没有人工批准引用时验证失败。
- `GOV-011`：`releasable` 缺任一人工证据时验证失败。
- `GOV-012`：运行脚本不会修改 manifest 或 governance 文件。

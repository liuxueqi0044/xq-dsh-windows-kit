# M03 PowerShell 公共安全内核

## 目标

为所有运行脚本提供唯一、可测试、无隐式副作用的安全函数，避免路径、版本、host 和脱敏规则分叉。

## 输入与输出

输入是 manifest、路径、版本文本、监听信息和待脱敏字符串；输出是具有 `Passed`、`Severity`、`Code`、`Message`、`Evidence` 的对象。公共函数不得直接 `exit`。

目标文件：`lib/XQDSH.Common.psm1`。不得依赖 PowerShell Gallery 模块。

## 依赖与非职责

依赖 M01 的 Schema 和支持矩阵。它不直接展示完整用户界面、不决定发布状态、不下载上游包、不创建工作区，也不启动或终止 DSH。

## 公共接口

- `Read-XQProductManifest`
- `Test-XQManifestRuntimePolicy`
- `ConvertTo-XQSemanticVersion`
- `Test-XQSupportedNodeVersion`
- `Resolve-XQCanonicalPath`
- `Test-XQSafeWorkspace`
- `Test-XQLoopbackHost`
- `Get-XQPortState`
- `Get-XQCommandInfo`
- `Get-XQDshHomePath`
- `Protect-XQSensitiveText`
- `Test-XQSensitiveText`
- `New-XQCheckResult`

函数名和参数在 M04–M06 实施前冻结。外部命令执行封装接受参数数组和超时，不接受拼接字符串。

## 版本规则

从 M01 的支持矩阵读取并验证批准范围：Node `22.19.0 <= v < 23.0.0` 或 24 LTS 主版本范围。预发布、无法解析、23.x、25.x 以及“更高所以应该兼容”的版本均不自动接受。

## 路径规则

规范化后比较 Windows 路径，大小写不敏感；拒绝根目录、宽目录、通配符、非法 provider 和 reparse point。检查函数不创建目录。

## 脱敏规则

使用多组小型、可解释正则，不使用单个灾难性回溯表达式。替换值统一为 `[REDACTED:<TYPE>]`。输入为空时保持为空；输出不得增长到不受控大小。

## 失败模式

公共函数对预期的无效输入返回结构化失败对象；只有程序错误才抛出异常。路径解析、版本解析或脱敏失败时调用方必须失败关闭，不得用原值继续。

## 验收标准

- `CORE-001`：Windows PowerShell 5.1 与 PowerShell 7 均能导入模块。
- `CORE-002`：导入模块不产生文件、网络、进程或环境变量变更。
- `CORE-003`：Node 22.18 被拒绝，22.19、22.x 后续和 24.x 被接受，23.x/25.x 被拒绝。
- `CORE-004`：根目录、用户根和已知宽目录被拒绝。
- `CORE-005`：默认窄工作区被接受，非空首次目录被阻断。
- `CORE-006`：reparse point 与路径逃逸被拒绝。
- `CORE-007`：仅 `127.0.0.1` 通过 host 检查。
- `CORE-008`：端口检查不会结束或修改占用进程。
- `CORE-009`：所有敏感 canary 被脱敏，非敏感版本号/路径不会被整体抹除。
- `CORE-010`：超长恶意文本的脱敏在测试超时内完成。
- `CORE-011`：外部命令参数不经过 `Invoke-Expression`、`cmd /c` 或脚本字符串求值。
- `CORE-012`：公共结果对象字段稳定，可被 JSON 序列化。

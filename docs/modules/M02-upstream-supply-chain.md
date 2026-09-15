# M02 上游供应链解析与验证

## 目标

从官方来源独立观察上游状态，并证明构建使用的 npm artifact、tag、commit 和 LICENSE 与冻结 manifest 一致。

## 输入

- M01 的 manifest 和 trusted sources；
- 官方 npm registry packument；
- 官方 GitHub tag/ref 与 LICENSE；
- 隔离 staging 目录。

## 输出

- `build/Resolve-OfficialPackage.ps1`；
- `build/Verify-NpmArtifact.ps1`；
- 机器可读 `source-observation.json`；
- 验证摘要和 hash 证据；
- 构建所需的已验证 LICENSE 副本。

## 依赖与非职责

依赖 M01 的信任根和冻结 manifest。本模块不决定产品应升级到哪个版本，不修改锁值，不运行 DSH，也不把缺少 provenance 描述成已获得供应链证明。

## 详细设计

解析器只观察，不运行下载包中的代码。顺序为：

1. 从 trusted sources 取得固定 URL；
2. 查询精确版本 packument 和 dist-tags；
3. 验证 package/name/version/repository/license/bin；
4. 下载 tarball 到新建 staging；
5. 计算 SHA-512 并与 SRI 比较，再计算 SHA-256；
6. 预扫描 tar entry，拒绝绝对路径、`..` 和路径逃逸；
7. 只提取允许的 `package.json`、README 和 LICENSE 用于比对；
8. 查询官方 tag 指向的完整 commit；
9. 下载该 tag 的 LICENSE 并计算 hash；
10. 将观察值与冻结 manifest 比较。

如果 registry 没有 `gitHead` 或 provenance，报告必须明确写 `UNAVAILABLE`，不得声称 tarball 与 commit 获得密码学绑定。tag→commit 与 tarball hash 仍分别锁定。

解析器记录 direct dependency ranges；若采用 `npx`，报告“顶层 artifact 已锁、传递依赖解析仍存在上游 semver 风险”。

## 网络约束

仅允许 HTTPS 和 trusted sources 中的主机。超时、TLS、重定向或响应类型异常均失败。不得回退到镜像。

## 失败模式

- 精确版本不存在或网络失败：退出码 4；
- 包名、版本、registry、SRI、SHA、tag、commit、LICENSE 任一不匹配：退出码 2；
- tar 路径逃逸或格式异常：退出码 2；
- provenance 不存在：形成显式风险，不自动等同于不匹配；发布策略决定是否阻断。

## 验收标准

- `SUP-001`：只查询官方 package 和 registry。
- `SUP-002`：dist-tags 变化不能改变精确候选版本。
- `SUP-003`：tarball SRI SHA-512 验证通过。
- `SUP-004`：tarball SHA-256 与 manifest 一致。
- `SUP-005`：tar entry 路径逃逸夹具被拒绝。
- `SUP-006`：tag 指向的完整 commit 与 manifest 一致。
- `SUP-007`：LICENSE 内容 hash 与 manifest 一致。
- `SUP-008`：包内 package.json 的 name/version/repository/license/bin 均符合预期。
- `SUP-009`：任一 byte 变化会导致验证失败。
- `SUP-010`：非官方重定向和 registry 被拒绝，不回退镜像。
- `SUP-011`：解析期间不运行 npm lifecycle 或包内 JS。
- `SUP-012`：缺少 gitHead/provenance 时报告真实状态和风险。
- `SUP-013`：记录 direct dependency ranges 和顶层锁的限制。
- `SUP-014`：形成 Web host 参数及 dump-config 写入行为的上游证据，供 M05/M06 使用。
- `SUP-015`：形成 `workspace-write + ask` 的真实配置字段、默认值和 resolved config 验证方式，供 M05 使用。

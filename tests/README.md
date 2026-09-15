# M06–M11 测试与门禁

M06–M11 的源码和本地自动化实现已完成，但真实 DSH、VM、人工抽查、GitHub main 绿色 run 和扩展生命周期证据仍按验收矩阵保持 `PENDING`。

本地验证（不运行在线 resolver 或候选构建）：

```powershell
powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1 -Mode Validate
pwsh -NoProfile -File .\tests\Invoke-Tests.ps1 -Mode Validate
Invoke-Pester -Script .\tests\M10-CI.Tests.ps1
```

候选流程仅在受保护的手动 workflow 中运行；它先完成 M01–M10（含 M09/M10）测试，再在线观察官方来源，生成独立 `xq.m10.prebuild-gate.v1`，最后调用候选构建。任何失败、PENDING、skipped、超时或缺失摘要均为失败；M11 人工验收不会被自动化冒充。

Pester 版本固定为 3.4.0；测试夹具中的秘密均为 `FAKE_TEST_*`，不得进入 ZIP。测试结果、Actions URL/run ID 和 VM 证据必须另行保存，不能用本地结果替代 main 绿色证据。

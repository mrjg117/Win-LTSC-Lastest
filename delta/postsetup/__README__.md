# 首启自定义脚本目录（postsetup）

往本目录丢 `.ps1` / `.cmd`，装机首启（setupcomplete.cmd 触发）会**自动按文件名顺序执行**，
调度器为 `Run-All.ps1`。

- 部署后落点：**`C:\PostSetup`**（顶层明显位置，方便你查找与清理）
- 不想自动跑：把脚本移出本目录，或只在需要时手动双击 `C:\PostSetup\Run-All.ps1`
- 跑完自清：在目录里放一个空文件 **`.clean.flag`**，`Run-All.ps1` 检测后删除整个 `C:\PostSetup`
- 不建计划任务、不建服务，符合「尽量不侵入系统」

> 示例脚本：`00-disable-hibernation.ps1`（关休眠）、`01-wsreset.ps1`（可选，默认注释）。
> 你的激活/配置脚本（企业 VL KMS/MAK 等）也放这里，内容合规由你把控。

# VC++ 官方独立包（redist）

放微软官方 redist（x86 + x64）：

- `vc_redist_2005.exe` / `2008` / `2010` / `2012` / `2013` 各自独立包
- `vc_redist_2015-2022.exe` 单合并包（覆盖 2015–2022）

构建期 `03.Integrate-VCpp.ps1` 提取并注入。脚本按文件名排序近似实现
「2005→2022、x86 先于 x64」的注入顺序。

> [SPIKE] VC++ 离线注入到 WinSxS 的具体命令需在 Windows runner 实机验证；
> 若官方 redist 对离线映像不可行，回退到可信 AIO（abbodi1406）离线 CAB。

# 驱动池（drivers）

把驱动文件（`.inf` / `.sys` / `.cat`，可多层子目录）丢进本目录。

- 构建期 `04.Integrate-Drivers.ps1` 用 `DISM /Add-Driver /Recurse` **全量注入 install.wim**。
- 部署时 Windows PnP **只安装硬件匹配的驱动**；不匹配的只占 DriverStore、不加载、不冲突、不蓝屏。
- 驱动文件本体体积小，进入磁盘的是匹配的那部分，并非整个 ISO 堆积。

## boot/ 子目录（最小集）

放 **存储 / RAID / NVMe / 网卡** 驱动最小集，注入 `boot.wim`（索引 2 Setup），
使安装器在特殊磁盘环境下也能识别硬盘。普通机器不需要额外驱动时，boot/ 可留空。

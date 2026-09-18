# 预装应用（apps，仅 Win11 分支 26100 生效）

放 MSIXBundle + `license.xml` + 框架依赖 msix（Windows App SDK Runtime / VC++ 运行时 appx 形式）。

建议命名：`Store*.msixbundle` / `Paint*.msixbundle` / `Notepad*.msixbundle` /
`MediaPlayer*.msixbundle` / `nanazip*.msixbundle`。

构建期 `05.Integrate-Apps.ps1` 按 **Store → Paint → Notepad → MediaPlayer → nanazip**
顺序 `DISM /Add-ProvisionedAppxPackage` 离线预装（每个带 license + 依赖）。

> 获取：用 `winget download --id Microsoft.Paint --source msstore` 等拉离线包；
> 或 Store for Business 离线分发。依赖必须齐备，缺一个注册失败。
> [SPIKE] 实际包名/依赖路径需实机校准。
>
> Win10 LTSC 2021（19044）分支**跳过**本目录——新版 MSIX 的 MinVersion 钉 Windows 11，
> 强行注入会报 `0x80073cfd`，故 Win10 使用内置经典 Notepad/Paint。

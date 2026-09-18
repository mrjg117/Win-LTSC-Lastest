# Win-LTSC-ISO（定制版）

基于 [adavak/Win_ISO_Patching_Scripts](https://github.com/adavak/Win_ISO_Patching_Scripts) 的滚动上游叠加层，
为 **Windows 10 LTSC 2021（19044）** 与 **Windows 11 IoT Enterprise LTSC 2024（26100）**
做「官方补丁集成 + VC/驱动/应用预装 + 组件精简 + 自动应答」，并在 GitHub Actions 出 ISO，
分发到 **仓库 Release（分块）/ Cloudflare R2 / OneDrive** 三端（各自独立保留数）。

本仓库是**纯 delta 叠加层**：上游 `W10UI.cmd` / `bin` 只读不写，只新增脚本与配置。

> 完整目录架构见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

---

## 一、需要你填的占位（首次必做）

1. **`config.yml` → `baseline.sha256`**：填两个官方 ISO 的真实 SHA256（从微软公开值或你下载源公示值核对）。
2. **`patchlist.json` → 每分支 `targetUBR` / `lcu`(kb,url,sha1) / `ssu`**：每月 Patch Tuesday 后更新 `targetUBR` 与补丁直链+SHA1（check-updates 会自动 bump `targetUBR`，但 `lcu.url/sha1` 建议人工确认）。
3. **Secrets**（仓库 Settings → Secrets，绝不进仓库文件）：
   - 三端上传按需：`R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_BUCKET`、`ONEDRIVE_RCLONE_CONF`（base64 编码的 rclone.conf）
   - `GITHUB_TOKEN` 由 Actions 自动提供，无需配置。

---

## 二、首次：上传官方基线 ISO

ISO 字节在你的机器上，本机跑一次（agent 沙箱无法代传）：

```powershell
# 本机已 gh auth login 后：
.\tools\upload-baseline.ps1 -IsoPath "D:\iso\Win11_LTSC_2024.iso" -Branch 26100
.\tools\upload-baseline.ps1 -IsoPath "D:\iso\Win10_LTSC_2021.iso" -Branch 19044
```

脚本会展示 SHA256，请你核对微软/来源公示值，再把该值填进 `config.yml` 的 `baseline.sha256`。
ISO 被 7z 分卷（≤1.9GiB）上传到仓库 `baseline` Release；工作流每次拉分块重组 + 校验。

---

## 三、触发方式

| 触发 | 说明 |
|---|---|
| **手动 `workflow_dispatch`** | 随时可跑；可指定分支、三端上传开关、各端保留数 |
| **每日 `check-updates`（事件驱动）** | 每日检测两分支最新累积更新 UBR；有新版本则自动 bump `patchlist.json` 并触发构建（默认仅传 Release） |
| **每月第3周三兜底 cron** | `build_iso.yml` 内 `schedule`；运行前查本月是否已有 Release，**已构建则跳过**，避免与事件驱动重复 |

---

## 四、三端存储与保留数

- **Release**：单文件硬限 2 GiB → ISO 自动 7z 分卷；资产免费、无过期、无带宽费。
- **R2 / OneDrive**：整文件直传；保留数 `KEEP_R2` / `KEEP_ONEDRIVE` 独立（R2 免费额度小，默认关，开时调 1~2）。
- 三端各自 `prune` 到保留数，旧的自动删。

---

## 五、首启自动执行（你用 WinNTSetup 装）

构建期把应答与脚本**离线烤进 install.wim 本体**（与部署工具解耦）：
- `C:\Windows\Panther\unattend.xml` — 一次性，首启用完系统自删 + 我们兜底删；
- `C:\Windows\Setup\Scripts\setupcomplete.cmd` — 薄引导，跑完自删，调 `Run-All.ps1`；
- `C:\PostSetup\*` — 你的自定义脚本（顶层明显，可清）。

WinNTSetup 里选源 WIM / 引导盘 / 目标盘 → 点「开始安装」即可，脚本全自动跑，无需手动选。

---

## 六、需实机验证的点（[SPIKE]，当前为骨架）

- **W10UI.cmd 输入/输出路径**：黑盒补丁集成引擎，其与本地 `updates\` 补丁目录衔接、输出 `install.wim` 位置需实机校准（`Patch.cmd` 已标注）。
- **VC++ 离线注入**：官方 redist 注入 WinSxS 的命令需 Windows runner 实机验证（脚本含 `/extract` + `msiexec /a` + `dism /Add-Package` 路线与回退说明）。
- **应用预装依赖**：appx + license + 框架依赖（WinAppSDK/VC++）需 `winget download` 获取并校准路径。
- **组件包名**：T1/T2 精简包名需用 `Get-WindowsPackage` 在真机校准准确字符串。
- **check-updates 检测源**：Catalog/UUPdump 解析需实机校准（解析失败不静默触发，等每日重试）。
- **驱动**：全量池注入 `install.wim` 留盘，PnP 仅装匹配硬件（已按你决定采用「留盘」方案）。

---

## 七、文件清单

```
config.yml / patchlist.json / win10ui-override.ini / last-build.json
delta/Patch.cmd                      总入口
delta/lib/00~99 *.ps1                各阶段脚本（预检/清单/下载/VC/驱动/应用/精简/断言/烤入/强制ini）
delta/assets/{drivers,redist,apps}  静态载荷（你往里丢文件）
delta/postsetup/                     首启自定义脚本（落 C:\PostSetup）
delta/config/{unattend-*.xml,setupcomplete.cmd}
.github/workflows/build_iso.yml      主构建
.github/workflows/check-updates.yml  每日检测
tools/upload-baseline.ps1            本机上传基线 ISO
```

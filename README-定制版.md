# Win-LTSC-ISO（定制版）

基于 [adavak/Win_ISO_Patching_Scripts](https://github.com/adavak/Win_ISO_Patching_Scripts) 的滚动上游叠加层，
为 **Windows 10 LTSC 2021（19044）** 与 **Windows 11 IoT Enterprise LTSC 2024（26100）**
做「官方补丁集成 + VC/驱动/应用预装 + 组件精简 + 自动应答」，并在 GitHub Actions 出 ISO，
分发到 **仓库 Release（分块）/ Cloudflare R2 / OneDrive** 三端（各自独立保留数）。

本仓库是**纯 delta 叠加层**：上游 `W10UI.cmd` / `bin` 只读不写，只新增脚本与配置。

> 完整目录架构见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

---

## 一、需要你填的占位（首次必做）

1. **`config.yml` → `baseline.sources`**：源镜像清单，一条镜像一行（`branch` + 完整下载直链 + `sha256`）。**这是下载地址与哈希的唯一存放处**，工作流不重复写；产物构建份数也由这里的条数决定。
2. **`config.yml` → `postsetup`**：首启脚本开关在此调（MAS / 关休眠 / 关预留空间 / 虚拟内存 / wsreset / 跑完自清），**改这些不必碰脚本**；`components`/`apps`/`drivers`/`storage`/`trigger` 也都在这里。
3. **`patchlist.json` → 每分支 `targetUBR` / `lcu`(kb,url,sha1) / `ssu`**：每月 Patch Tuesday 后更新 `targetUBR` 与补丁直链+SHA1（check-updates 会自动 bump `targetUBR`，但 `lcu.url/sha1` 建议人工确认）。
4. **Secrets**（仓库 Settings → Secrets，绝不进仓库文件）：
   - 三端上传按需：`R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_BUCKET`、`ONEDRIVE_RCLONE_CONF`（base64 编码的 rclone.conf）
   - `GITHUB_TOKEN` 由 Actions 自动提供，无需配置。

---

## 二、首次：拉取官方基线 ISO

无需本机传封。到仓库 Actions 手动跑一次 **`Fetch Baseline ISO`** 工作流即可 —— 全部逻辑都在**工作流内**（纯 bash，无外部脚本）：

1. 按 `config.yml` 的 `baseline.sources` 逐条下载官方 ISO（直链完整写、各源域名可不同、不做拼接；下载文件名 = URL 末段，即微软原版名）；
2. 用清单里同一条的 `sha256` 校验，不符即中止；
3. RAW 顺序字节切分（`baseline.chunk_mib`，默认 1900 MiB/片，无压缩）→ `<微软原版ISO名>.part1/2/3…`；
4. 生成内嵌全部源镜像哈希的 `merge.cmd`，连同分块上传到 `baseline` Release，并清理该 Release 上的一切其它残留资产。

产物固定只有两样：`<微软原版ISO名>.partN` 与 `merge.cmd`。
取用：把 `merge.cmd` 和全部 `.partN` 下到同一目录，双击 `merge.cmd` 即自动 `copy /b` 重组 ISO 并核对 SHA256。

> **加镜像源 = 在 `config.yml` 的 `baseline.sources` 加一条**（该分支还需在 `patchlist.json` 有定义）：
> 先跑 `Fetch Baseline ISO` 把它上传到 `baseline`，再跑 `Build ISO` —— 产物会自动多一份，全程无需改工作流。

---

## 三、触发方式

| 触发 | 说明 |
|---|---|
| **手动 `workflow_dispatch`** | 随时可跑；三端上传开关与各端保留数可调（**构建哪些分支由 `baseline.sources` 决定，不需要手选**） |
| **每日 `check-updates`（事件驱动）** | 每日检测两分支最新累积更新 UBR；有新版本则自动 bump `patchlist.json` 并触发构建（默认仅传 Release） |
| **每月第3周三兜底 cron** | `build_iso.yml` 内 `schedule`；运行前查本月是否已有 Release，**已构建则跳过**，避免与事件驱动重复 |

---

## 四、三端存储与保留数

- **Release**：单文件硬限 2 GiB → 成品 ISO 自动 RAW 切分（每片 ≤1.9GiB，逐片上传后即刻删除以控磁盘）；每个 Release 附带 `merge.cmd`，内嵌本 ISO 期望哈希。
  取用：把 `merge.cmd` 和全部 `.partN` 下到同一目录，双击 `merge.cmd` 即自动重组 ISO 并核对 SHA256：
  ```bat
  merge.cmd
  ```
  （baseline 原版 ISO 同样 RAW 切分：`zh-cn_windows_11_enterprise_ltsc_2024_x64_dvd_cff9cd2d.iso.part1/2/3…`，配同一份 `merge.cmd`。）
- **R2 / OneDrive**：整文件直传；保留数 `KEEP_R2` / `KEEP_ONEDRIVE` 独立（R2 免费额度小，默认关，开时调 1~2）。
- 三端各自 `prune` 到保留数，旧的自动删。
- **产出命名**：Release 标签 `YYMMDD-UBR-W10` / `YYMMDD-UBR-W11`；ISO 名 `zh-cn_windows_11_enterprise_ltsc_2024_x64_YYMMDD_UBR.iso`（含日期+UBR）。baseline 用微软原版名，源镜像与产出明显分开。

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
.github/workflows/fetch-baseline.yml 首次拉取官方基线（下载/校验/RAW切分/merge.cmd）
tools/local-test.ps1                 本机管理员冒烟测试（不参与 CI）
```

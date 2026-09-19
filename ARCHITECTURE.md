# Win-LTSC-ISO 目录架构（规划稿 · 待评审）

> 自有仓库 = **纯 delta 叠加层 + 配置 + 工作流**。构建时把 `delta/` 整目录拷进「上游快照 `./src`」，再执行。
> 上游 `adavak/Win_ISO_Patching_Scripts` 每次拉最新 `master`，只读 `W10UI.cmd` / `bin`，不写。

---

## 一、自有仓库根结构

```
Win-LTSC-ISO/                         ← 你的公开仓库
├── .github/
│   └── workflows/
│       ├── build_iso.yml             # 主构建：拉上游 → 套 delta → 出 ISO → 三端上传 + 独立 prune
│       └── check-updates.yml         # 每日检测更新，有更新/重要更新才触发 build_iso
│
├── delta/                            # 叠加层（构建时整目录拷进 ./src）
│   ├── Patch.cmd                     # 总入口：管理员校验 + 编排 A→B→W10UI→E→D
│   ├── lib/                          # PowerShell 模块，按阶段编号拆分，互不污染
│   │   ├── 00.Precheck.ps1           # 预检 fail-fast：校验 W10UI.ini/cmd/bin 存在且名字没变
│   │   ├── 01.Build-Manifest.ps1     # 改造A：读 DISM build/arch → 权威表 → UBR → 出 manifest.json
│   │   ├── 02.Fetch-Updates.ps1      # 改造B：aria2 多线程下载 (-x16 -s16 -c) + SHA1 校验
│   │   ├── 03.Integrate-VCpp.ps1     # 扩展E：离线注入 VC++ 官方逐项 (2005~2022, x86→x64)
│   │   ├── 04.Integrate-Drivers.ps1  # 驱动池注入 install.wim（留盘，PnP 按需装）+ boot.wim 最小集
│   │   ├── 05.Integrate-Apps.ps1     # 离线 provision Store/Paint/Notepad/MediaPlayer/nanazip(仅Win11)
│   │   ├── 06.Patch-Components.ps1   # 精简组件：T1 Capability + T2 IoT Removable Packages
│   │   ├── 07.Assert-UBR.ps1         # 改造D：断言 build主版本一致 ∧ UBR≥target ∧ 目标KB已装
│   │   ├── 08.Bake-Image.ps1         # 离线烤入 WIM：C:\PostSetup + setupcomplete.cmd + Panther\unattend.xml（WinNTSetup 兼容）
│   │   ├── 09.Gen-PostSetup.ps1      # 读 config.yml -> postsetup.settings.json（首启配置，被 08 烤入 C:\PostSetup）
│   │   └── 99.Force-W10UI-Ini.ps1    # 强制两行：wim2esd=0 / ResetBase=0（不整文件覆盖）
│   ├── assets/                       # 静态载荷（按分支可选，构建时拷进 ./src）
│   │   ├── drivers/                  # 驱动池：递归塞全部，部署时 PnP 只装匹配硬件的
│   │   │   └── boot/                 # 最小集：存储/RAID/NVMe/网卡 → 注入 boot.wim
│   │   ├── redist/                   # VC++ 官方独立包（2005/2008/2010/2012/2013 + 2015-2022 合并）
│   │   └── apps/                     # 预装 appx + license + 框架依赖（仅 Win11 分支）
│   ├── postsetup/                    # 首启脚本 → 落 C:\PostSetup（明显位置，可清）
│   │   ├── Run-All.ps1               # 调度器：顺序跑 .ps1/.cmd，按 .clean.flag 自清
│   │   ├── Apply-Settings.ps1        # 按 postsetup.settings.json 应用 MAS/关休眠/关预留空间/虚拟内存/wsreset
│   │   ├── postsetup.settings.json   # 构建期由 config.yml 生成（被 08 烤入映像）
│   │   └── __README__.md             # 说明：往这目录丢 .ps1/.cmd 就自动被首启执行
│   ├── config/
│   │   ├── unattend-26100.xml        # 应答模板，构建期离线烤进 WIM 的 C:\Windows\Panther\unattend.xml
│   │   ├── unattend-19044.xml
│   │   └── setupcomplete.cmd         # 首启引导，离线烤进 WIM 的 C:\Windows\Setup\Scripts\（调 Run-All.ps1）
│   └── win10ui-override.ini          # 仅两行强制值，供 99.Force-W10UI-Ini.ps1 写回
│
├── patchlist.json                    # 每分支目标 UBR / LCU / 组件精简清单 / 驱动集（构建引擎读它，按月更新）
├── config.yml                        # 【唯一控制面板】组件/应用/驱动开关、postsetup(首启脚本)、存储、触发、baseline
├── merge.cmd                         # 通用合并+校验：RAW 分块双击即重组 ISO 并核对 SHA256（随每个 Release 发布）
├── last-build.json                   # 构建成功写入（cron 兜底读它去重，避免重复构建）
├── tools/
│   └── upload-baseline.ps1           # 本机一次性：ISO 分包(≤1.9GiB) → baseline Release + .sha256 清单
└── README-定制版.md
```

---

## 二、构建时叠加映射（自己的库 → 上游快照 → ISO）

```
你的仓库 delta/  ──整目录拷贝──▶  ./src (上游 master 快照)
        │                                  + delta/Patch.cmd
        │                                  + delta/lib/*.ps1
        │                                  + delta/assets/{drivers,redist,apps}
        │                                  + delta/postsetup/*  ──离线条烤──▶ WIM 内 C:\PostSetup
        │                                  + setupcomplete.cmd ──离线条烤──▶ WIM 内 C:\Windows\Setup\Scripts\
        │                                  + unattend.xml     ──离线条烤──▶ WIM 内 C:\Windows\Panther\
        │                                  （均为离线写入 install.wim，与部署工具无关，WinNTSetup 也生效）
        │                                  - 删除 update-meta4.yml（被改造A取代）
        │                                  + win10ui-override.ini 强制两行
        │
从 own baseline Release 拉分块 → RAW 顺序字节重组(copy /b) → SHA256 校验 → 挂载 ./src/ISO/
        │
./src/Patch.cmd ──▶ 7z解ISO → DISM读build/arch → A清单 → B下载 → W10UI集成 → E(VC/驱动/应用) → 06精简 → D断言 → oscdimg封装
        │
成品 ISO ──▶ RAW 切分(≤1.9GiB/片, .part1/2/3) + 生成带哈希的 merge.cmd ──▶ Release(分块+merge.cmd) + R2(可选) + OneDrive(可选)
          Release 标签格式：YYMMDD-UBR-W10 / YYMMDD-UBR-W11；ISO 名：zh-cn_windows_XX_..._x64_YYMMDD_UBR.iso
          baseline Release：两个原版 ISO 的 RAW 分块 + merge.cmd（源镜像与产出明显分开）   [KEEP_RELEASE / KEEP_R2 / KEEP_ONEDRIVE 各自独立]
```

---

## 三、缓存策略（跨次复用，降消耗）

`build_iso.yml` 用 `actions/cache` 跨工作流运行保存已下载载荷，避免每次重复拉取：

| 缓存 key | 内容 | 收益 |
|---|---|---|
| `updates-<branch>-<UBR>` | 当月累积/SSU/DU 下载 | 同分支重启只增量拉新 UBR；用 `restore-keys: updates-<branch>-` 前缀匹配上月 |
| `drivers-<hash>` | 驱动池（静态） | 大节省，几乎不重下 |
| `redist-<hash>` | VC++ 官方包 | 一次性 |
| `apps-<hash>` | appx 包 + 依赖 | Win11 分支一次性 |

- 公开仓库 `actions/cache` 免费；总缓存上限 10 GB；**7 天未用回收**（月度构建足够，不会丢）。
- baseline ISO 本身从 own Release 拉（直连快），不进缓存。
- 命中缓存时 `Fetch-Updates.ps1` 跳过已存在文件的下载（`aria2 -c` 续传）。

---

## 四、镜像层自动应答（你用 WinNTSetup 在 PE 里装 → 已适配）

**先纠正**：之前按「标准 ISO 启动 setup.exe」说的 `sources\$OEM$` 自动拷贝，**在 WinNTSetup 下不成立**。WinNTSetup 是直接 `dism/wimglib apply` 把 WIM 铺到分区 + `bcdboot` 写引导，**不跑标准 Setup 的 `$OEM$` 处理**。所以脚本/应答**必须离线烤进 WIM 本体**，才能与部署工具解耦。

**结论：全程自动化，没有「手动选脚本」这一步。** 做法改为「构建期离线写入 install.wim」：

1. **`C:\Windows\Panther\unattend.xml`（离线烤进 WIM）** — 首启时 Windows Setup **自动读取并套用**（分区/版本/密钥/跳过 OOBE）。无需你在 WinNTSetup 里挑文件；也兼容 WinNTSetup 自带的「Unattend」字段（你若想用别的应答可另选，不强制）。
2. **`C:\Windows\Setup\Scripts\setupcomplete.cmd`（离线烤进 WIM）** — 首启以 `SYSTEM` 身份**自动跑一次**，调用 `C:\PostSetup\Run-All.ps1`；不建计划任务、不建服务。
3. **`C:\PostSetup\*`（离线烤进 WIM）** — 顶层明显位置，你随时可清；`Run-All.ps1` 顺序执行其中脚本。
4. **双保险**：`unattend.xml` 里再加 `FirstLogonCommands` 在首次登录跑一次 `Run-All.ps1`，万一 `setupcomplete.cmd` 在某些 WinNTSetup 精简模式下未触发，仍能兜底执行。

**文件残留与清理（你问的关键点）—— 不是「一直留着」**：
- `C:\Windows\Panther\unattend.xml`：**部署一次性**。Windows 首启在 specialize 阶段读取并消费它后，从 Win8 起 **Setup 会自动删除该文件**（安全默认，防明文密码/密钥残留）。即「烤进去 → 首启用一次 → 系统自动删」，不占硬盘。我们不 100% 依赖系统清理（精简镜像可能不触发该 pass），故 `setupcomplete.cmd` 末尾**显式兜底删** `Panther\unattend.xml` 与 `Panther\Unattend\`，确保干净。
- `C:\Windows\Setup\Scripts\setupcomplete.cmd`：**Windows 不自动删**（它是自定义薄引导，系统不知何时该删）。故脚本末尾 `del /f /q %~f0` **自删**，不留痕。
- `C:\PostSetup\*`：由 `config.yml` 的 `postsetup.clean_after_run` 决定——`true` 构建期烤入 `.clean.flag`，`Run-All.ps1` 首启跑完自清；`false` 留着审计/二次执行。首启的具体行为（MAS/关休眠/关预留空间/虚拟内存/wsreset）全部读 `postsetup.settings.json`，该文件由 `config.yml` 生成，改配置不必碰脚本。
- **结论**：`unattend`=一次性（系统删+兜底删）；`setupcomplete`=薄引导（自删）；`PostSetup`=你的脚本（你决定留删）。三样均不建服务、不建计划任务、不侵入系统。
5. **驱动**：构建期已用 `DISM /Add-Driver` 离线烤进 WIM（部署时 PnP 只装匹配硬件的）；WinNTSetup 的「Add Drivers」选项可作为补充，但非必需。

> WinNTSetup 的固有手动步（选源 WIM / 引导盘 / 目标盘）是 PE 部署本身的操作，与「选脚本」无关——脚本全自动跑，你只需点一次「开始安装」。

所以「丢脚本进 `postsetup/` → 烧 ISO → WinNTSetup 一键铺完 → 首启全自动执行」，无需任何人工脚本选择。

## 五、WinNTSetup 适配要点（对照原方案改动）

| 原方案（标准 Setup） | 改为（WinNTSetup 兼容） |
|---|---|
| `$OEM$\$1\PostSetup` 自动拷贝 | 离线 `copy` 进 WIM 的 `C:\PostSetup` |
| `$OEM$\$$\Setup\Scripts\setupcomplete.cmd` | 离线写入 WIM `C:\Windows\Setup\Scripts\setupcomplete.cmd` |
| `sources\autounattend.xml` 自动识别 | 离线写入 WIM `C:\Windows\Panther\unattend.xml`（首启自动读） |
| 依赖标准 Setup 最终化阶段 | 双触发：setupcomplete.cmd + FirstLogonCommands 兜底 |

---

## 五、分区职责一览（避免乱堆）

| 目录 | 职责 | 谁动 |
|---|---|---|
| `delta/lib/*.ps1` | 构建期各阶段逻辑，按编号顺序 | 你/我维护 |
| `delta/assets/drivers` | 驱动池（全量，留盘） | 你往里丢 .inf/.sys/.cat |
| `delta/assets/drivers/boot` | 最小驱动集（boot.wim） | 你往里丢 |
| `delta/assets/redist` | VC++ 官方包 | 一次放好 |
| `delta/assets/apps` | 预装 appx + 依赖 | Win11 分支 |
| `delta/postsetup` | 装机后自定义脚本 | 你往里丢 |
| `delta/config` | 自动应答 + $OEM$ 模板 | 按需改 |
| `patchlist.json` | 每分支目标 UBR/组件/驱动集 | 每月换 |
| `config.yml` | 全局开关 | 随时改 |

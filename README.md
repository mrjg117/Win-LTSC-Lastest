# Win-LTSC-Lastest

滚动构建 **Windows 10 / 11 IoT Enterprise LTSC** 定制镜像的 GitHub Actions 流水线。

| | |
|---|---|
| 补丁引擎 | 上游 `Win_ISO_Patching_Scripts`（**唯一依赖**，只 clone 不修改） |
| 本仓库 | **纯 delta 叠加层** —— 配置 + 自有脚本 + 工作流，不含上游任何文件 |
| 输入 | 微软原版 LTSC ISO（按清单下载 + SHA256 强校验） |
| 处理 | 集成当月补丁 → SKU 转 IoT LTSC → 精简组件 → 驱动 → 应用预置 → 离线写入优化与应答 |
| 输出 | 带日期与 UBR 的定制 ISO，RAW 分块发布到 Release（可选 R2 / OneDrive） |

---

## 一、文件树（每个文件干什么）

```
.
├── config.yml                         【唯一控制面板】见第二节
├── README.md                          本文件（唯一文档）
├── .gitignore
│
├── .github/workflows/
│   ├── fetch-baseline.yml             拉微软原版 ISO → SHA256 校验 → RAW 切分 → baseline Release
│   ├── build_iso.yml                  主构建：解析配置 → 按分支并行出 ISO → 三端上传 + 各自 prune
│   ├── check-updates.yml              每日检测微软更新；有新版本则触发构建
│   └── keepalive.yml                  定时空提交保活（公开仓库 60 天无活动会被停用定时任务）
│
├── assets/
│   └── release/
│       └── merge.cmd                  发给下载者的重组工具：与全部分片放同一目录，双击即重组 + 校验
│
├── delta/                             叠加层（构建时整目录拷进上游快照）
│   ├── Patch.cmd                      总入口：管理员校验 + 顺序编排（00 → 99 → W10UI → 01…07）
│   ├── win10ui-override.ini           不随配置变的红线值（wim2esd=0 / ResetBase=0），99 写回上游 ini
│   │
│   ├── lib/                           构建期各阶段脚本，编号即执行顺序
│   │   ├── 00.Precheck.ps1                预检 fail-fast：上游文件 / delta 脚本 / config.json / 磁盘
│   │   ├── 01.Build-Manifest.ps1          读 WIM 的 build·arch + 分支定义 → manifest.json
│   │   ├── 02.Fetch-Updates.ps1           按上游 meta4 下载当月 LCU / SSU 到 patch\
│   │   ├── 03.Integrate-Drivers.ps1       注入 assets/drivers（放文件就注入）
│   │   ├── 04.Integrate-Apps.ps1          按 apps 清单离线预置 MSIX
│   │   ├── 05.Patch-Components.ps1        按 remove 清单精简组件
│   │   ├── 06.Assert-UBR.ps1              断言 build 落在 family 内，回写实测 UBR
│   │   ├── 07.Bake-Image.ps1              挂载 WIM：Set-Edition 转 IoT + 离线注入优化 + 应答 + C:\Tools
│   │   └── 99.Force-W10UI-Ini.ps1         把红线值 + optimize 组 A 写回上游 W10UI.ini
│   │
│   ├── config/
│   │   └── unattend.xml               应答模板（区域 / 时区 / OOBE），构建期烤进 WIM
│   │
│   └── assets/                        【素材目录】放文件 = 生效，不放 = 不做
│       ├── apps/                      预置应用载荷 + 可选 license.xml（构建期自动抓取）
│       ├── drivers/                   驱动池 → 递归注入 install.wim（留盘，PnP 按需装）
│       ├── drivers/boot/              最小驱动集 → 注入 boot.wim
│       ├── redist/                    组件载荷（构建期自动抓取；烤进 C:\Tools\redist，不注入镜像）
│       └── mas/                       激活工具包 → 烤进 C:\Tools\MAS\（不自动运行）
│
└── tools/
    ├── config-to-json.py              config.yml -> config.json（含结构性校验，构建前 fail-fast）
    ├── fetch-payloads.py              按 config 抓取 components / apps 载荷到 delta/assets/
    └── local-test.ps1                 本机管理员冒烟测试（不参与 CI）
```

---

## 二、控制面板 `config.yml`

**全文只有一条规则：写了 = 启用；注释掉 / 不写 = 停用。** 没有 `false`，没有 `KEEP`，没有成对开关。

| 段 | 形态 | 语义 |
|---|---|---|
| `baseline.sources` | 映射列表 | 一行一条源镜像（完整 URL + sha256）；**产物份数 = 条数** |
| `remove` | 列表 | 组件名，写了就卸；**全局表，对所有分支生效** |
| `branches.<b>.remove` | 列表 | 本分支**额外**卸（与全局表合并去重），重复的不用写两遍 |
| `branches.<b>.apps` | 列表 | 本分支应用（与全局 `apps` 合并去重），同上 |
| `branches.<b>.label` / `edition` / `family` | 单值 / 列表 | 产物标签后缀来源；目标 SKU；允许的 build 家族 |
| `branches.<b>.detect` | 单值 | 去 Update Catalog 搜「本产品最新累积更新」的搜索词（**填产品名，不要填 build 号** —— 见第七节） |
| `gvlk` | 映射 | SKU 转换用的 KMS GVLK（微软官方文档值） |
| `components` | 映射 | `名字: 链接`，有链接才下载并烤入 `C:\Tools\redist` |
| `apps` | 列表 | 写一行装一个（12 位 Store 产品 ID 或完整直链） |
| `optimize` | 列表 | 优化项名字，写了就生效（组 A 走上游 ini，组 B 走离线注入） |
| `storage` | 映射 | `release` / `r2` / `onedrive`，值 = 保留份数 |

`remove` 的名字形态由脚本自动分流，**不匹配任何形态即报错退出**（不静默跳过）：

```
含 ~~~~           → Capability       （例 XPS.Viewer~~~~0.0.1.0）
以 -Package 结尾  → Package          （例 Microsoft-Windows-UEV-Package）
其余              → Optional Feature （例 MicrosoftWindowsPowerShellV2）
```

`config.yml` 在构建前由 `tools/config-to-json.py` 转成 `config.json`（Linux 侧一次解析 + 结构性校验：
未知顶层键、空的 sources、分支没定义、edition 不在 gvlk 表、optimize 写了没人实现的项……全在这里拦下）。
Windows 侧脚本只读 JSON，因此不需要在 runner 上装 YAML 库。

---

## 三、构建流程

```
① fetch-baseline.yml
   按 config 的 sources 逐条下载原版 ISO（aria2 多线程）
   → 同条 sha256 校验 → RAW 切分 <原名>.partN → 上传 baseline Release
   （baseline Release 上只留 <原名>.partN + merge.cmd，其它残留自动清理）

② build_iso.yml
   plan 任务（Linux）：config.yml → config.json（+校验）→ 生成分支矩阵 → config.json 作为 artifact 下传
   build 任务（Windows runner）：
     clone 上游最新 master        （URL 是本仓库唯一的硬编码常量；不钉 ref，持续吃上游更新）
     下载 config.json artifact
     套 delta 到上游快照 → 抓取载荷（tools/fetch-payloads.py：components + apps）
     从 baseline Release 拉分片 → 重组 → 校验 → 解 ISO
     Patch.cmd 顺序执行：
       00 预检 → 99 写上游 ini → 解 baseline ISO → 01 清单 → 02 下载更新
       → W10UI 把补丁集成进 install.wim → 03 驱动 → 04 应用 → 05 精简 → 06 断言
       → 07 挂载 WIM：Set-Edition 转 IoT + 离线注入优化 + 应答 + C:\Tools
     封装 ISO → RAW 切分 → 上传 Release（可选 R2 / OneDrive）→ 各自 prune
```

| 缓存 | 内容 |
|---|---|
| `updates-<branch>-<UBR>` | 当月累积/SSU 下载，重启只增量拉新 |
| `drivers-<hash>` / `redist-<hash>` / `apps-<hash>` | 静态载荷，几乎不重下 |

---

## 四、产物命名与取用

| | 格式 |
|---|---|
| Release 标签 | `<YYMMDD>-<UBR>-Win10` / `<YYMMDD>-<UBR>-Win11` |
| 成品 ISO 名 | `zh-cn_windows_1x_..._x64_<YYMMDD>_<UBR>.iso` |
| 分片 | `<ISO 名>.part1 / .part2 / …`（每片 ≤ 1.9 GiB，避开 GitHub 2 GiB 单文件上限） |
| 重组工具 | `merge.cmd`（每个 Release 附带，内嵌本 ISO 的 SHA256） |

取用：把 `merge.cmd` 和**全部** `.partN` 下到同一目录，双击 `merge.cmd` → 自动 `copy /b` 重组并核对 SHA256。

`Win11` / `Win10` 后缀由 `branches.<b>.label` 推导，**唯一生成点**在 `build_iso.yml` 的 plan 任务
（拼进 `EDITION` 变量）；下游标签拼装、幂等 SKIP 判断、三端 prune 通配全部引用它 —— 只改 label 一处，全链路跟随。
UBR 用 06 实测值，不猜。

---

## 五、装完之后：目标系统的落地

### 5.1 只有一个自建目录 `C:\Tools\`

| 路径 | 内容 |
|---|---|
| `C:\Tools\激活系统.cmd` | 双击 → UAC 提权 → 调用 MAS（**不自动运行**） |
| `C:\Tools\MAS\` | 激活工具包（构建期从 `delta/assets/mas/` 烤入） |
| `C:\Tools\安装运行库.cmd` | 双击 → UAC 提权 → 依次静默安装 `redist\` 里的组件（**不自动运行**） |
| `C:\Tools\redist\` | 组件载荷（构建期从 `delta/assets/redist/` 烤入） |
| `C:\Windows\Panther\unattend.xml` | 应答文件（区域 / 时区 / OOBE）。Windows 机制位，两侧都不额外建目录 |

除上述之外，镜像不往 C 盘写任何自建文件：不建服务、不建计划任务、不留首启脚本。

> **为什么组件是「烤进去 + 手动一键」而不是注入镜像**：`DISM /Add-Package` 只接受 `.cab`/`.msu`，
> 而 VC++ 可再发行包是 MSI/exe —— 官方口径明确不能这样离线集成，唯一官方途径是部署后静默安装
> （`vc_redist.x64.exe /install /quiet /norestart`）。所以它被烤进 `C:\Tools\redist\` 并附一键入口。
> 这样既不动镜像的组件存储，也不假装"已集成"。

### 5.2 优化设置：全部离线烤进镜像

`optimize` 清单里两类都是**构建期**生效，装完第一次开机就是改好的，不依赖任何启动脚本：

- **组 A（上游 ini 开关）** —— 由上游 `W10UI.cmd` 自己做的离线 hive 注入，我们只改 ini 的值，零自造代码。
  由 `99.Force-W10UI-Ini.ps1` 写入；若上游改了键名，99 会**直接报错**而不是静默失效。
- **组 B（自补项）** —— 在 `07.Bake-Image.ps1` 已有的挂载会话里 `reg load` 目标 hive 写入，
  收尾仍是一次 `Dismount -Save`，不多挂一次。涉及三个 hive：`SYSTEM` / `SOFTWARE` / `Users\Default\NTUSER.DAT`。

> 写 `Users\Default\NTUSER.DAT` 只对**之后新建**的用户生效 —— 正因为我们是「装完系统才建账户」，这条通道才好用。
> `Policies` 路径的键优先级高于用户级键，用户改不回去（遥测、消费者体验、广告 ID 这类要锁死的项）；
> 界面类则写默认用户 hive，只当默认值，用户随时可改。
> 离线 hive 里没有 `CurrentControlSet`（那是运行时符号链接），所以写 `ControlSet001/002…` —— 存在几份就写几份。

### 5.3 自动应答的边界

`Panther\unattend.xml` **只做三件事**：区域/输入法、时区与计算机名、OOBE 减负。
**只对 specialize / oobeSystem 阶段生效** —— windowsPE 段（选版本 / 跳密钥 / 分区）放这里是死的，
那需要 ISO 根的 `\autounattend.xml`，而它**只在从 ISO 引导标准安装时有效，WinNTSetup 不读**
（它直接 apply wim + bcdboot，选盘选版本在它界面里点）。用 WinNTSetup 部署时，现在这套路径是对的。

不预建账户、不自动登录、不跳「用户 OOBE」—— 要免联网建本地账户，用 `optimize` 里的 `oobebypass`。

### 5.4 SKU：构建时转到 IoT Enterprise LTSC

`07.Bake-Image.ps1` 在挂载会话里 `DISM /Set-Edition` 到 `branches.<b>.edition`（密钥取 `gvlk` 表）。
IoT 相比普通 Enterprise LTSC 的差别：预留存储默认关、BitLocker 自动加密默认关、无 TPM/安全启动/内存硬件要求、
支持周期 10 年、**支持数字权利激活（普通 LTSC 只有 KMS/MAK）**；代价是 Edge 不可卸载。

---

## 六、首次配置清单

1. `config.yml` → `baseline.sources`：源镜像清单（完整直链 + sha256）。**地址与哈希只此一处。**
2. `config.yml` → 其余段：按需删注释。
3. `delta/assets/` → 想注入的驱动 / MAS 工具包 / license.xml，放进去即生效。
4. Secrets（仓库 Settings → Secrets，**绝不进仓库文件**）：
   - Release 上传用 Actions 自带的 `GITHUB_TOKEN`，无需配置；
   - R2 / OneDrive 按需：各自的凭据走 Secrets。
5. 首次跑 `Fetch Baseline ISO` 填充 baseline Release，再跑 `Build ISO`。

**加一个源镜像** = 在 `baseline.sources` 加一条，并在 `branches` 里给它一节定义 →
先跑 `Fetch Baseline ISO` → 再跑 `Build ISO`，产物自动多一份，工作流不用改。

---

## 七、触发方式

| 触发 | 说明 |
|---|---|
| 手动 `workflow_dispatch` | 随时可跑；构建哪些分支由 `baseline.sources` 决定，不需要手选 |
| 每日 `check-updates` | 去 Update Catalog 查该产品最新累积更新，比已有产物标签新就触发构建（不写任何文件、不 commit） |
| 每月兜底 cron | `build_iso.yml` 内定时；运行前查本月是否已有 Release，已构建则跳过 |
| `keepalive` | 定时空提交保活（防 60 天无活动被 GitHub 停用定时任务） |

### 7.1 `check-updates` 的判据（为什么不用 build 号）

搜 `windows 11 build 26100 cumulative` 之类会把**同 build 号的 Server 版**混进结果（实测那页里
Server 是 `26100.33451`，客户端真值却是 `26100.9457`），取最大值必然误判；而 Win10 的结果行
`Version` 列一律是 `n/a`，按 build 号根本取不到值。所以：

- 每个分支在 `config.yml` 里配一个 `detect` 词，**填产品名**（如 `Windows 11, version 24H2`、
  `Windows 10 Version 21H2`）；工作流用它拼 `"<detect> Cumulative Update"` 去搜，只留
  x64、正式版、非 `.NET`、非「预览版」的那一行 —— 这样首页第一条就是该产品最新的累积更新。
- 比较基准取**这一行里能拿到的最强信号**：标题尾巴带 `(build.UBR)`（Win11 全系都带）且该 build
  落在本分支 `family` 内 → 比 UBR；拿不到 build（Win10 全系）→ 退回比发布日期。
  标签 `<YYMMDD>-<UBR>-Win<10|11>` 里两个字段都有，无需第二份真相源。
- 网络/解析失败一律**不触发**，等下一次定时跑，绝不因为一次抓取失败就误触发或漏报成功。

---

## 八、已知取舍与待实测项

| 项 | 状态 |
|---|---|
| 应用包下载渠道 | 微软官方只给「产品 ID → WuCategoryId」（`displaycatalog.mp.microsoft.com`，无需认证）。真正的包 URL 在 WU 交付服务里，要过 [MS-WUSP] 的签名与时效 Cookie —— 所以 `tools/fetch-payloads.py` 用社区事实标准 `store.rg-adguard.net` 换链接（**它返回的仍是微软官方 CDN 直链**）。这是第三方单点，失败时会直接报错，不会静默漏包 |
| 应用 license | `license.xml` 公开渠道拿不到（需 Entra 认证，Store for Business 已于 2024-08 退役）。规则：同名 `.xml` 放对应载荷目录就带上，没有则 `/SkipLicense` + 开 `AllowAllTrustedApps`。**存在付费类应用不激活的风险** |
| Win10 分支的 MSIX | 新版 MSIX 的 `MinVersion` 钉 Windows 11，强注会报 `0x80073cfd` → 该分支的 apps 留空 |
| 转 IoT 的 SKU 转换 | 中文镜像 `install.wim` 通常只有一个 index，但 `Dism /Get-TargetEditions` 允许升到 `IoTEnterpriseS`。**需首次实跑确认**（07 里已按官方 GVLK 写死映射，并做了转换后复检） |
| 组件包名 / 功能名 | `remove` 里的名字需用 `Get-WindowsPackage` / `Get-WindowsCapability` 在真机校准；不存在或已被 LCU 取代的项会 SKIP |
| 驱动 | 全量池注入 `install.wim` 留盘，PnP 只装匹配硬件 |
| VC++ 等运行库 | **无法离线注入**（DISM 只吃 cab/msu）→ 走 `C:\Tools\redist` + 一键安装入口，见 5.1 |

### 8.1 脚本的文本编码约定（改脚本前必读）

`Patch.cmd` 是用 `powershell`（**Windows PowerShell 5.1**，不是 pwsh）调 `lib\*.ps1` 的，
而 5.1 读**无 BOM 的 UTF-8** 脚本时会按系统 ANSI 代码页解码 —— 脚本里的中文字面量会先烂掉
（`07` 生成的 `C:\Tools\激活系统.cmd`、`安装运行库.cmd` 文件名和内容都会变乱码）。因此：

| 对象 | 约定 | 原因 |
|---|---|---|
| 全部 `.ps1` | **UTF-8 带 BOM** | 5.1 / 7 都按 UTF-8 正确解码；无 BOM 在 5.1 上会被当 ANSI |
| `manifest.json`、生成的 `.cmd` | **UTF-8 无 BOM**（用 .NET `UTF8Encoding($false)` 写） | 同一句 `Set-Content -Encoding UTF8` 在 5.1 写 BOM、在 7 不写，行为会随宿主漂移；显式 .NET 编码才两端一致 |
| 上游 `W10UI.ini` | **字节保真**（ISO-8859-1 做 1:1 字节映射读写） | 它的编码不由我们控制；只改命中的 ASCII 键，未命中行逐字节不动，绝不写 BOM、不换换行符 |
| `config.json` | 读时一律带 `-Encoding UTF8` | 不要依赖「不带 `-Encoding` 的 `Get-Content`」的宿主默认值 |

> 顺带一个 .NET 正则坑：`(?m)^key=value$` **匹配不到 CRLF 行尾**（`$` 只在 `\n` 前成立，
> 中间还夹着 `\r`）。要按行断言就切行后做字符串相等，别用 `^…$` 锚点。

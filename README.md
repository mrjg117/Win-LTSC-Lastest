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
│   │   ├── 07.Bake-Image.ps1              挂载 WIM：Set-Edition 转 IoT + 离线注入 registry + 应答 + C:\Tools
│   │   └── 99.Force-W10UI-Ini.ps1         把红线值 + optimize.ini 写回上游 W10UI.ini
│   │
│   ├── config/
│   │   └── unattend.xml               应答模板（区域 / 时区 / OOBE），构建期烤进 WIM
│   │
│   └── assets/                        【素材目录】放文件 = 生效，不放 = 不做
│       ├── apps/                      预置应用载荷 + 可选 license.xml（构建期自动抓取）
│       ├── drivers/                   驱动池 → 递归注入 install.wim（留盘，PnP 按需装）
│       ├── drivers/boot/              最小驱动集 → 注入 boot.wim
│       ├── redist/                    组件载荷（构建期自动抓取；07 按安装器类型写进应答）
│       ├── overwrite/                 组件安装后的文件覆盖（`<组件名>/` 下放文件即生效，见 5.2）
│       └── mas/                       激活工具包 → 烤进 C:\Tools\MAS\（不自动运行）
│
└── tools/
    ├── config-to-json.py              config.yml -> config.json（含结构性校验，构建前 fail-fast）
    ├── fetch-payloads.py              按 config 抓取 components / apps 载荷到 assets/redist
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
| `apps` | 列表 | 写一行装一个（12 位 Store 产品 ID 或完整直链）；选包规则见下 |
| `optimize.ini` | 映射 | `开关名: 一句话说明`；99 把该键在上游 `W10UI.ini` 里置 1 |
| `optimize.registry` | 映射 | `开关名: "hive\|path\|name\|type\|value"`（或该串的列表）；07 挂载镜像时离线写 hive |
| `optimize.components` | 映射 | `名字: 安装器直链`；构建期抓取 → 07 写进应答，首启静默安装 |
| `optimize._extensions` | 列表 | `{ext}` 占位符的取值清单（仅当有 registry 项用到 `{ext}` 时才需要写） |
| `storage` | 映射 | `release` / `r2` / `onedrive`，值 = 保留份数 |

`remove` 的名字形态由脚本自动分流，**不匹配任何形态即报错退出**（不静默跳过）：

```
含 ~~~~           → Capability       （例 XPS.Viewer~~~~0.0.1.0）
以 -Package 结尾  → Package          （例 Microsoft-Windows-UEV-Package）
其余              → Optional Feature （例 MicrosoftWindowsPowerShellV2）
```

`optimize.components` 只接受**安装包**，装法是「构建期写进应答 → 首次开机静默安装」，**不匹配即报错退出**：

```
.exe  → 安装包（安装器类型自动识别，判不出就报错，绝不猜参数）
           Inno Setup  → /VERYSILENT /SP- /SUPPRESSMSGBOXES /NORESTART
           NSIS        → /S
           vc_redist   → /install /quiet /norestart
.msi  → 安装包：msiexec /i "<文件>" /qn /norestart
.zip  → 若内含**唯一**一个 .exe/.msi，就地解出内层安装器（外层 zip 丢弃）
        其余形态原样保留 → 由 07 按扩展名报错
```

**安装路径与设置一律走官方默认**：不传 `/DIR`、不传 `INSTALLDIR`、不勾选/取消任何组件：
- MPC-BE（x64 安装器）→ `C:\Program Files\MPC-BE x64`（官方 `distrib\mpc-be_setup.iss` 的
  `DefaultDirName={pf}\MPC-BE x64`；`ArchitecturesInstallIn64BitMode=x64` 保证 `{pf}`= 真 Program Files）
- Neat Download Manager（Inno Setup）→ `C:\Program Files (x86)\Neat Download Manager`（32 位应用）
- 默认组件（main / mpciconlib / mpcresources / mpcvr）与默认快捷方式全保留
- 运行库（VC++ 2010 / 2015-2022、.NET 9、DirectX Jun2010）装到系统默认目录（System32 / Program Files），无需指定
- 解压工具 **NanaZip** 走 `apps` 段（MSIX 正常应用，按 Store 流程离线预置），不在此列

> 载荷选择跟着**官方发行形态**走，不自己拼：
> MPC-BE 官方只发 `MPC-BE.<ver>.x64.7z`（便携）与 `MPC-BE.<ver>.x64-installer.zip`（内含单个 Inno 安装器）
> —— 要装到 Program Files 就走后者。
> 7-Zip 已弃用：改用 **NanaZip**（同为 7-Zip 内核，MSIX 形态，作为正常应用预置）。

装完想替换掉安装器铺下的某个文件（典型：换汉化版主程序），就把它按**组件名 + 原相对路径**
放进 `delta/assets/overwrite/<组件名>/`，构建期会打进 `C:\Tools\install\ow_<组件名>\`，
并在该组件的安装命令后追加一条 `copy /y` 覆盖 —— 纯复制，不写字节、不依赖任何外部工具：

```
delta/assets/overwrite/ndm/NeatDM.exe       →  覆盖 %ProgramFiles(x86)%\Neat Download Manager\NeatDM.exe
```

> 目录名**必须**是 `optimize.components` 里的组件名（否则构建期报错，不静默忽略），
> 且该组件的安装器载荷要真在 `assets/redist` 下；覆盖目标目录走官方默认路径，
> 遇到没登记过默认路径的组件名直接报错 —— **绝不猜路径**。

**为什么不是「离线注入镜像」**：`DISM /Add-Package` 只吃 `.cab`/`.msu`，NSIS/Inno 安装器没有
任何官方途径在构建期直接写进镜像内部。可行落点是构建期把静默命令行写进镜像里 **Windows 自带的应答机制**，
首次开机由系统自己执行 —— 得到的是正常安装（可卸载、在「应用和功能」里有条目、装到 Program Files）。
跑完由 cmd **自删应答文件与载荷目录**，成品机上不留任何自建脚本或计划任务。

`apps` 的选包规则（同一产品 ID 常返回多个候选产物）：
先要 **x64 / neutral**（arm 系一律丢弃）→ 再取包名里**版本号最大**的那个。
刻意不按体积排 —— 体积排序会选中旧版（实测 Media Player 会选到 2019 年的 48.5 MB 包，
而现行版 `11.2607.16.0` 只有 38.4 MB）。加密包（`.eappxbundle` / `.emsixbundle`）
无法离线预置，按扩展名直接丢弃。

`config.yml` 在构建前由 `tools/config-to-json.py` 转成 `config.json`（Linux 侧一次解析 + 结构性校验：
未知顶层键、空的 sources、分支没定义、edition 不在 gvlk 表、registry 竖线串段数/类型不对、
`{ext}` 用了却没给清单、components 值不是直链……全在这里拦下）。
**它同时是竖线串的唯一解析点**：`"hive|path|name|type|value"` 在这里被拆成 JSON 对象并逐字段校验，
Windows 侧脚本只读对象、只补 `REG_` 前缀，不再重复拆字符串 —— 同一份数据只有一处解释规则。
Windows 侧脚本只读 JSON，因此不需要在 runner 上装 YAML 库。

> 载荷怎么进到工作目录：`tools/fetch-payloads.py` 抓发布件到 `delta/assets/redist/`。
> 构建期只需要「一份仓库」——CI 走 `cp -r self/delta/* src/` 本来就带上了 `config.json` 与 `assets/`，
> 本地复现也只需 clone 上游 + 跑这个脚本，不用先手抄一份 delta。

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
     套 delta 到上游快照 → 抓取载荷（tools/fetch-payloads.py：optimize.components / apps → assets/redist）
     从 baseline Release 拉分片 → 重组 → 校验 → 解 ISO
     Patch.cmd 顺序执行：
       00 预检 → 99 写上游 ini → 解 baseline ISO → 01 清单 → 02 下载更新
       → W10UI 把补丁集成进 install.wim → 03 驱动 → 04 应用 → 05 精简 → 06 断言
       → 07 挂载 WIM：Set-Edition 转 IoT + 离线注入 registry + 应答 + C:\Tools
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
| `C:\Tools\install\` | 组件安装器载荷 + `ow_<组件名>\` 覆盖文件（**首次开机自动安装后自删**，见 5.2） |
| `C:\Windows\Panther\unattend.xml` | 应答文件（区域 / 时区 / OOBE + 组件静默安装）。Windows 机制位，**装完自删** |

除上述之外，镜像不往 C 盘写任何自建文件：不建服务、不建计划任务、不留首启脚本。

> **安装到哪儿了？** 组件走各自**官方默认路径**，都在 `C:\Program Files\` 下，跟手动安装完全一样：
> `C:\Program Files\MPC-BE x64\`（有 `mpc-be64.exe`，桌面/开始菜单快捷方式已建）、
> `C:\Program Files (x86)\Neat Download Manager\`（32 位应用）、
> 运行库（VC++ / .NET / DirectX）装到系统默认目录。
> 都可在「设置 → 应用和功能」里正常卸载 —— 因为它们就是真的安装过。
> 解压工具 **NanaZip** 是 MSIX 应用（WindowsApps 下），同样可在「应用和功能」里卸载。

### 5.2 组件怎么装上的：Windows 自己的应答机制，不是首启脚本

`optimize.components` 里的安装器由 `07.Bake-Image.ps1` 写进 `unattend.xml` 的 **`synthesize` pass**
（`RunSynchronous`），首次开机时由 Windows 自己执行，跑完自删：

```xml
<settings pass="synthesize">
  <component name="Microsoft-Windows-Deployment" ...>
    <RunSynchronous>
      <SynchronousCommand wcm:action="add">
        <Order>1</Order>
        <CommandLine>cmd.exe /c cd /d "%SystemDrive%\Tools\install" &amp;&amp; "7z2603-x64.exe" /S</CommandLine>
      </SynchronousCommand>
      ...
```

**安装器类型自动识别，判不出就报错，绝不猜参数**：

| 形态 | 命令行 |
|---|---|
| Inno Setup | `/VERYSILENT /SP- /SUPPRESSMSGBOXES /NORESTART` |
| NSIS | `/S` |
| vc_redist | `/install /quiet /norestart` |
| `.msi` | `msiexec /i "<文件>" /qn /norestart` |
| `.zip` | 若内含**唯一**一个 `.exe`/`.msi`，构建期就地解出内层安装器（外层 zip 丢弃） |
| 其余 | 原样保留 → 由 07 按扩展名报错 |

**覆盖文件**（如换汉化版主程序）走 `assets/overwrite/<组件名>/`，由 4c 步追加在**该组件安装命令之后**
（顺序严格保证装完再覆盖）：

```xml
<SynchronousCommand wcm:action="add">
  <Order>5</Order>
  <CommandLine>cmd.exe /c cd /d "%SystemDrive%\Tools\install" &amp;&amp; if exist "%ProgramFiles(x86)%\Neat Download Manager\NeatDM.exe" copy /y "ow_ndm\NeatDM.exe" "%ProgramFiles(x86)%\Neat Download Manager\NeatDM.exe"</CommandLine>
</SynchronousCommand>
```

几个已实测定案的细节（改这块务必保留）：

| 细节 | 为什么 |
|---|---|
| 每条命令都 `cd /d "%SystemDrive%\Tools\install" && …` | RunSynchronous 的 cwd 是 `%SystemRoot%\System32`，不 cd 就找不到安装器（**失败还很安静**） |
| `<Order>` **从 1 递增且唯一** | 实测两次都写 `1` 时只认第一条 |
| 组件段 `<component>` **自带 `xmlns:wcm`** | 基础模板把它声明在各自 `<component>` 上（不是根节点）；漏了 → `wcm 是未声明的前缀`，整份 XML 非法、Windows 静默拒收 |
| 合并后**构建期就用 `[xml]` 解析一遍** | 上面那类问题在构建期炸掉，别等装机才发现 |
| 收尾自删 `Panther\unattend.xml` + `Tools\install` | 成品机上不留应答文件与载荷 |

> 用了 `synthesize` 而不是 `oobeSystem\FirstLogonCommands`：前者在**无人应答阶段**执行，
> 不依赖任何用户登录，也不需要在 OOBE 里塞命令。

### 5.3 优化与组件：全部数据都在 `config.yml` 一处

`optimize` 段是**唯一数据源**，三个英文子键各对应一个执行器。全部**构建期**生效，
装完第一次开机就是改好的，不依赖任何启动脚本、不需要任何外部表文件：

```
config.yml ── optimize ──┬── ini        ──▶  99.Force-W10UI-Ini.ps1   （键置 1 写回上游 W10UI.ini）
                         ├── registry   ──▶  07.Bake-Image.ps1        （挂载镜像时 reg load → 写 → unload）
                         ├── components ──▶  07.Bake-Image.ps1        （抓载荷 → 写进应答 → 首启静默装）
                         └── _extensions                     （{ext} 占位符的取值清单，供 registry 展开）
```

**代码里不含任何具体优化项**：`07` 只有「挂载 / 加载 hive / 按对象写值 / 展开占位符」四个通用动作，
加一个优化项 = 往 `config.yml` 加一行，脚本一行都不用改。

#### `optimize.ini` —— 上游 `W10UI.ini` 的开关

值是**一句话说明，纯注释用途**；执行器统一把同名键置 1：

```yaml
optimize:
  ini:
    nosuggapp:   禁第三方应用静默安装
    oobebypass:  OOBE 免联网建本地账户
```

> 这些键全部是上游 `W10UI.ini` 自己的开关，上游会做离线 hive 注入 —— 我们**零自造代码**。
> 键名在上游 ini 里不存在会直接报错（上游可能改了名字），不静默跳过。

#### `optimize.registry` —— 离线 hive 写入

值是**竖线分隔的五段串**（或这种串的列表）：

```
hive | path | name | type | value
```

| 段 | 说明 |
|---|---|
| `hive` | `SYSTEM` / `SOFTWARE` / `DEFAULT`（= `Users\Default\NTUSER.DAT`） |
| `path` | 注册表路径。`{CS}` = 该 hive 里**所有** `ControlSetNNN`（离线 hive 没有 `CurrentControlSet`，那是运行时符号链接） |
| `name` | 值名；留空 = 该键的默认值 |
| `type` | **裸名** `DWORD` / `SZ` / `EXPAND_SZ`（写入时脚本自己拼 `REG_` 前缀） |
| `value` | 值；`DWORD` 写数字。**段内可以再含竖线** —— 只切前 4 个分隔符 |

```yaml
optimize:
  registry:
    disable_hibernate: "SYSTEM|{CS}\\Control\\Power|HibernateEnabled|DWORD|0"
    taskbar_align_left: "DEFAULT|Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced|TaskbarAl|DWORD|0"
    # 一开关多写、多个键同源 → 用列表
    photo_viewer_legacy:
      - "SOFTWARE|Classes\\Applications\\photoviewer.dll\\shell\\open|MuiVerb|SZ|@%ProgramFiles%\\Windows Photo Viewer\\photoviewer.dll,-3043"
      - "SOFTWARE|Microsoft\\Windows Photo Viewer\\Capabilities\\FileAssociations|{ext}|SZ|PhotoViewer.FileAssoc.Tiff"
```

`{ext}` 占位符对 `optimize._extensions` 里**每个取值各写一次**（`path` / `name` / `value` 里都能用）：

```yaml
optimize:
  _extensions: [.bmp, .dib, .gif, .ico, .jfif, .jpe, .jpeg, .jpg, .jxr, .png, .tif, .tiff, .wdp]
```

> 路径/值里其它的花括号（CLSID、`{FFE2A43C-…}`）是值本身的一部分，不是占位符 —— 只有 `{CS}` 与 `{ext}` 会被替换。
> `photo_viewer_legacy` 就靠 `{ext}` 把多条 shell 注册 + 13 个扩展名关联一次写完（5 条 → 展开成 17 条写入）。
> 表格数据（`Classes\Applications\photoviewer.dll\shell\open` 与
> `Microsoft\Windows Photo Viewer\Capabilities\FileAssociations`）与实测的本机 Win11 24H2 注册表逐字一致，不猜。
> ProgID 一律用 `PhotoViewer.FileAssoc.Tiff` —— 实测 Win10/11 上其余 ProgID（Jpeg/Png/Bitmap/Gif/Icon/Wdp）
> 都已被移除，只剩这一个还是完整的树。补完只是让它**出现在**打开方式 / 默认应用里；
> 真正设为默认仍需用户点一下 —— `UserChoice` 带微软的哈希校验，离线写不了。

#### `optimize.components` —— 组件安装

值 = **安装器直链**（有链接才抓、才装），落地形态与覆盖机制见 5.2：

```yaml
optimize:
  components:
    vc14_x64:       https://aka.ms/vs/17/release/vc_redist.x64.exe      # VC++ 2015-2022
    vcredist_x64:   https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6B958/vcredist_x64.exe  # VC++ 2010
    dxruntime:      https://download.microsoft.com/download/6/5/B/65B16A3D-6D7F-4C2D-BC0C-9B8B1A9C0E8E/directx_Jun2010_redist.exe  # DirectX Jun2010
    dotnet9_desktop: https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/9.0.18/windowsdesktop-runtime-9.0.18-win-x64.exe  # .NET 9
    mpcbe:  https://github.com/Aleksoid1978/MPC-BE/releases/download/1.9.1/MPC-BE.1.9.1.x64-installer.zip
    ndm:    https://www.neatdownloadmanager.com/file/NeatDM_setup.exe
```
> 解压工具 **NanaZip** 不再放 `components`，而是放 `apps`（MSIX 正常应用，离线预置，见 5.1）。

#### 防呆（任一处不对都直接报错，绝不静默失效）

| 检查点 | 时机 | 脚本 |
|---|---|---|
| 未知顶层键 / 未知 optimize 子键 | 构建前 | `tools/config-to-json.py` |
| 竖线串段数不足 5、未知 hive、未知 type、`DWORD` 值不是数字、`path` 为空 | 构建前 | `tools/config-to-json.py`（`parse_reg_value`） |
| `{ext}` 用了却没给 `_extensions`；`_extensions` 写了却没人用 | 构建前 | `tools/config-to-json.py` |
| `components` 值不是完整直链 / 扩展名无法分流 / 有名字没链接 | 构建前 | `tools/config-to-json.py` |
| `ini` 的键在上游 `W10UI.ini` 里不存在（上游改名了） | 构建期 | `99.Force-W10UI-Ini.ps1` |
| registry 项字段不全 / 指定了不支持的 hive / 展开时清单为空 | 构建期 | `07.Bake-Image.ps1` |
| `assets/overwrite/<名>` 的名字不在 `components` 里 / 组件默认路径未登记 | 构建期 | `07.Bake-Image.ps1` |
| `optimize` 三个子键缺任何一个（config.json 被改坏） | 构建期第一步 | `00.Precheck.ps1` |

> 写 `Users\Default\NTUSER.DAT` 只对**之后新建**的用户生效 —— 正因为我们是「装完系统才建账户」，这条通道才好用。
> `Policies` 路径的键优先级高于用户级键，用户改不回去（遥测、消费者体验、广告 ID 这类要锁死的项）；
> 界面类则写默认用户 hive，只当默认值，用户随时可改。
> 离线 hive 里没有 `CurrentControlSet`，所以写 `ControlSet001/002…` —— 存在几份就写几份（幂等）。

### 5.4 自动应答的边界

`Panther\unattend.xml` **只做三件事**：区域/输入法、时区与计算机名、OOBE 减负。
**只对 specialize / oobeSystem 阶段生效** —— windowsPE 段（选版本 / 跳密钥 / 分区）放这里是死的，
那需要 ISO 根的 `\autounattend.xml`，而它**只在从 ISO 引导标准安装时有效，WinNTSetup 不读**
（它直接 apply wim + bcdboot，选盘选版本在它界面里点）。用 WinNTSetup 部署时，现在这套路径是对的。

不预建账户、不自动登录、不跳「用户 OOBE」—— 要免联网建本地账户，用 `optimize` 里的 `oobebypass`。

### 5.5 SKU：构建时转到 IoT Enterprise LTSC

`07.Bake-Image.ps1` 在挂载会话里 `DISM /Set-Edition` 到 `branches.<b>.edition`（密钥取 `gvlk` 表）。
IoT 相比普通 Enterprise LTSC 的差别：预留存储默认关、BitLocker 自动加密默认关、无 TPM/安全启动/内存硬件要求、
支持周期 10 年、**支持数字权利激活（普通 LTSC 只有 KMS/MAK）**；代价是 Edge 不可卸载。

---

## 六、首次配置清单

1. `config.yml` → `baseline.sources`：源镜像清单（完整直链 + sha256）。**地址与哈希只此一处。**
2. `config.yml` → 其余段：按需删注释。
3. `delta/assets/` → 想注入的驱动 / MAS 工具包 / license.xml / 组件覆盖文件，放进去即生效。
4. Secrets（仓库 Settings → Secrets，**绝不进仓库文件**）：
   - Release 上传用 Actions 自带的 `GITHUB_TOKEN`，无需配置；
   - R2 / OneDrive 按需：各自的凭据走 Secrets。**上传已去掉 rclone，改走原生直传**：
     - R2（S3 直传，curl `--aws-sigv4`，零安装）：
       `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ACCOUNT_ID` / `R2_BUCKET` / `R2_REGION`（留空默认 `auto`）
     - SharePoint（Microsoft Graph 证书鉴权 + 可续传 upload session，零安装，目标=**默认站点/默认文档库**）：
       `ONEDRIVE_TENANT_ID` / `ONEDRIVE_CLIENT_ID` / `ONEDRIVE_SITE_HOST`（默认站点主机名，形如 `contoso.sharepoint.com`，应用权限 `Files.ReadWrite.All` 或 `Sites.ReadWrite.All`）
       / `ONEDRIVE_CERT_THUMBPRINT`（证书 SHA1 指纹，十六进制，可选）/ `ONEDRIVE_CERT_KEY`（证书**私钥 PEM** 全文，含换行）
       - 密钥对：Entra ID 应用注册 → Certificates 上传证书(公钥 .cer)，私钥自己留存填进 `ONEDRIVE_CERT_KEY`；
         token 用 `client_assertion`(私钥签 JWT) 换，不过期，比 rclone 的 OAuth refresh token 稳。
       - 上传路径落在默认文档库 `WinLTSC/<tag>/` 下；脚本用 `GET /sites/{host}` 解析默认站点、取其默认 drive。
5. 首次跑 `Fetch Baseline ISO` 填充 baseline Release，再跑 `Build ISO`。

**加一个优化项** = 在 `config.yml` 的 `optimize.registry`（或 `.ini`）里加一行 —— 代码一行都不用改。

**加一个组件** = 在 `optimize.components` 加一行 `名字: 直链`；要覆盖它的某个文件就再建
`delta/assets/overwrite/<该名字>/` 放文件。

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
| Win10 分支的 MSIX | **实测修正**：原以为「新版 MSIX 的 `MinVersion` 钉 Win11、强注报 `0x80073cfd`」。实测现行 Store 包 `Microsoft.WindowsStore_22608.1401.3.0` 的 `TargetDeviceFamily` 为 `MinVersion=10.0.18362.0`（Win10 1903）/ `MaxVersionTested=10.0.26100.0` → 19044 满足，两分支共用同一产品 ID 即可。**判断某个包能不能装，去读它的 manifest，别按印象推** |
| 预装应用取舍 | 商店包只留 **Microsoft Store 本体**（LTSC 出厂不带，放全局 `apps` 一次两分支共用）。画图 / 记事本用 LTSC 自带的经典版；播放器用 MPC-BE、解压用 NanaZip（走 `apps` 段 MSIX 预置，见 5.1）。商店版 Paint / 照片是 AI 重型包 —— Paint bundle 722 MB 里 330 MB 是 `.onnxe` 模型权重，新版照片 1117 MB 里约 596 MB 是 AI 载荷 —— 对 LTSC 是纯负重 |
| 转 IoT 的 SKU 转换 | 中文镜像 `install.wim` 通常只有一个 index，但 `Dism /Get-TargetEditions` 允许升到 `IoTEnterpriseS`。**需首次实跑确认**（07 里已按官方 GVLK 写死映射，并做了转换后复检） |
| 组件包名 / 功能名 | `remove` 里的名字需用 `Get-WindowsPackage` / `Get-WindowsCapability` 在真机校准；不存在或已被 LCU 取代的项会 SKIP |
| 驱动 | 全量池注入 `install.wim` 留盘，PnP 只装匹配硬件 |
| VC++ 运行库 / .NET / DirectX / MPC-BE / NDM | **无法构建期注入镜像**（DISM 只吃 cab/msu）→ 写进 `unattend.xml` 的 synthesize pass，首次开机静默装到官方默认路径（见 5.2）；NanaZip 走 `apps` 段按 MSIX 预置 |

### 8.1 脚本的文本编码约定（改脚本前必读）

`Patch.cmd` 是用 `powershell`（**Windows PowerShell 5.1**，不是 pwsh）调 `lib\*.ps1` 的，
而 5.1 读**无 BOM 的 UTF-8** 脚本时会按系统 ANSI 代码页解码 —— 脚本里的中文字面量会先烂掉
（`07` 生成的 `C:\Tools\激活系统.cmd` 文件名和内容都会变乱码）。因此：

| 对象 | 约定 | 原因 |
|---|---|---|
| 全部 `.ps1` | **UTF-8 带 BOM** | 5.1 / 7 都按 UTF-8 正确解码；无 BOM 在 5.1 上会被当 ANSI |
| `config.yml` / `config.json` | **UTF-8**；读时一律带 `-Encoding UTF8` | 不要依赖「不带 `-Encoding` 的 `Get-Content`」的宿主默认值 |
| `manifest.json`、生成的 `.cmd` | **UTF-8 无 BOM**（用 .NET `UTF8Encoding($false)` 写） | 同一句 `Set-Content -Encoding UTF8` 在 5.1 写 BOM、在 7 不写，行为会随宿主漂移；显式 .NET 编码才两端一致 |
| 上游 `W10UI.ini` | **字节保真**（ISO-8859-1 做 1:1 字节映射读写） | 它的编码不由我们控制；只改命中的 ASCII 键，未命中行逐字节不动，绝不写 BOM、不换换行符 |
| Python 脚本的 `print` | 开头 `sys.stdout.reconfigure(encoding="utf-8", errors="replace")` | CI 的 Windows runner 是 en-US，stdout 回退 cp1252，一打印中文就 `UnicodeEncodeError` 整步挂掉（本机 cp936 永远测不出来） |
| Python 脚本的 `import` | 提交前跑一遍 `python -m pyflakes tools/*.py` | 漏一个 import 在**运行到那一行时**才炸，编译期（`py_compile`）查不出来 —— 实测 `fetch-payloads.py` 漏 `import zipfile`，本地没走到解包分支所以全绿，CI 必挂 |
| `shell: bash` 里调 `python` | 可以调，`actions/setup-python` 已把 `python.exe` 注入 PATH | Windows runner 的 Git Bash **能**解析 `python`（runner 日志实测该 step 正常下载组件）；分支参数用 `"${{ matrix.branch }}"` 带引号 |

> **改脚本/表之后务必复查 BOM**：`Edit`/`Write` 工具可能把 BOM 抹掉，而 `.ps1` 少了 BOM
> 在 5.1 上会静默变成 ANSI 解码 —— 中文先烂，报的却是「意外的标记」这类看不出根因的语法错。
> 一条命令查全部：读前 3 字节 == `ef bb bf` 才算带 BOM。

> 顺带一个 .NET 正则坑：`(?m)^key=value$` **匹配不到 CRLF 行尾**（`$` 只在 `\n` 前成立，
> 中间还夹着 `\r`）。要按行断言就切行后做字符串相等，别用 `^…$` 锚点。

### 8.2 「代码只走逻辑，行为进配置」的落点

本仓库刻意区分**逻辑**与**行为数据**，改需求时先想清楚该动哪边：

| | 放在哪 | 例子 |
|---|---|---|
| **逻辑**（通用动作） | 脚本里 (`delta/lib/*.ps1`, `tools/*.py`) | 挂载镜像 / 加载卸载 hive / 按对象写值 / 展开占位符 / 识别安装器类型 / 解析 YAML / 校验 |
| **行为数据**（做什么） | `config.yml` 一处 | 写哪个键、写成什么值、装哪个组件、覆盖哪个文件、卸哪个包、预置哪个应用 |

判据很简单：**加一个数据项应该不用改代码**。如果非要改 `lib/*.ps1` 才能加一条优化，
那说明它写错了位置 —— 应该进 `config.yml`。反过来，脚本里出现 `if ($name -eq '某个具体开关')`
或者一张硬编码的「开关名 → 动作」映射表也是信号：那是行为数据漏进了代码。

> 曾经把优化项拆到 `delta/assets/optimize/{ini,hive}.json` 两张外部表 —— **已废弃**。
> 名字和值分散两处必然漂移，而且 `config.yml` 就在手边，没有理由为「分类」多维护一份文件。
> 现在分类由 `optimize` 的子键本身表达，不需要任何中间映射。

已经按这个约定落地的三处，也是本仓库最容易被改歪的地方：

- `optimize`：`config.yml` 一处写全（`ini` / `registry` / `components`，见 5.3）；
  竖线串的解析点唯一在 `tools/config-to-json.py`，Windows 侧只读已解析好的对象。
- `components` 的落地形态靠**安装器类型与扩展名分流**，覆盖目标靠**登记过的官方默认路径**，
  不逐项写死命令。
- `remove` / `apps` 的清单在 `config.yml`，分流靠**值形态**（`~~~~`/`-Package`、12 位产品 ID / 直链）。

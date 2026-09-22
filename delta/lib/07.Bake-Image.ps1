<#
.SYNOPSIS 07 - 烤入镜像（SKU 转 IoT + 离线优化注入 + 应答 + C:\Tools）
.DESCRIPTION 挂载 install.wim，在一次挂载会话里做完五件事，收尾只 Dismount -Save 一次：
             1) Set-Edition     目标 SKU 取 config.json 的 branches.<分支>.edition，
                                 密钥取 gvlk 表（DISM /Set-Edition 用官方 GVLK）
             2) 离线优化注入    读 config.json 的 optimize.registry（竖线格式的写入表），
                                 把注册表写进目标 hive
                                 （SYSTEM / SOFTWARE / Users\Default\NTUSER.DAT）
                                 装完第一次开机就是改好的 —— 不依赖任何首启脚本
             3) C:\Tools\       目标系统上唯一的自建目录
                                   MAS\  + 激活系统.cmd   （要手动跑一次）
                                   install\               （组件安装器，首启自装后自删）
             4) 组件安装        config.json 的 optimize.components 的安装器 (.exe/.msi) 由
                                 **应答文件**（synthesize pass RunSynchronous）在首次开机
                                 静默安装，落到各自官方默认目录（C:\Program Files\…），装完自删。
                                 assets\overwrite\<组件名>\ 下放了文件的话，会在该组件安装命令
                                 之后追加一条覆盖命令（见 4c）。
             5) 应答文件        config\unattend.xml（基础项）+ 上面生成的组件安装段
                                 → 合并成一份 C:\Windows\Panther\unattend.xml

   [本脚本只提供逻辑，不含任何具体优化项]
   写哪个键、写成什么值，全部在 config.yml 的 optimize.registry 里 ——
   本文件只做四件通用的事：挂载镜像 / 加载卸载 hive / 按已解析的对象写值 / 展开占位符。
   加一个优化项 = 往 config.yml 加一行数据，这里一行都不用改。

   [为什么组件走应答而不是离线注入镜像]
   DISM /Add-Package 只接受 .cab/.msu，而 7-Zip / MPC-BE / NDM 都是 NSIS/Inno 安装器 ——
   官方口径明确不能这样离线集成。可行落点是：构建期把静默命令行写进镜像里 Windows 自带的
   应答机制，首次开机由系统自己执行，得到的是正常安装（可卸载、有「应用和功能」条目）。
   这不是「首启脚本」——机器上不留任何自建脚本或计划任务，命令只在 Panther 应答里，跑完自删。

   [注意] 离线 hive 里没有 CurrentControlSet（那是运行时的符号链接），
          必须写 ControlSetNNN；镜像里可能存在多份，故全部写入（幂等）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\07-bake.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

# ---- 注册表写入数据：来自 config.json 的 optimize.registry（本文件不含任何具体项）----
#   模式见 config.yml 的注释；要点：
#     · 配置里写的是 "hive|path|name|type|value" 竖线串，
#       **已由 tools/config-to-json.py 拆成对象并校验**（单一解析点，本文件不再重复拆）
#     · {CS}  = 该 hive 里所有 ControlSetNNN（离线 hive 无 CurrentControlSet 符号链接）
#     · {ext} = 展开型：对 optimize.extensions 里每个取值各写一次
#   本文件只提供「补类型前缀 / 展开」两个通用器，不含任何具体开关。
function ConvertTo-RegPut {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Put, [Parameter(Mandatory)] [string] $Where)
    foreach ($f in 'hive','path','name','type','value') {
        if ($null -eq $Put.PSObject.Properties[$f]) {
            throw "$Where 缺字段 $f（config.yml 的 registry 写法见该文件注释）"
        }
    }
    if (-not ([string]$Put.path).Trim()) { throw "$Where 的 path 不能为空" }
    # 写入用 reg.exe，类型要带 REG_ 前缀；config 里写的是裸名（DWORD/SZ/EXPAND_SZ）
    [pscustomobject]@{
        hive  = [string]$Put.hive
        path  = [string]$Put.path
        name  = [string]$Put.name
        type  = "REG_$([string]$Put.type)"
        value = [string]$Put.value
    }
}

# {ext} 展开：一条模板 -> 每个扩展名各一条（模板里没有 {ext} 就原样返回）
function Expand-RegPut {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Put, [Parameter(Mandatory)] [string[]] $Extensions)
    if ($Put.path -notlike '*{ext}*' -and $Put.name -notlike '*{ext}*' -and
        [string]$Put.value -notlike '*{ext}*') {
        return @($Put)
    }
    if ($Extensions.Count -eq 0) {
        throw "写入项用了 {ext} 但没有取值清单（optimize.extensions 为空）: $($Put.path)"
    }
    $out = @()
    foreach ($e in $Extensions) {
        $out += [pscustomobject]@{
            hive  = $Put.hive
            path  = ([string]$Put.path).Replace('{ext}', $e)
            name  = ([string]$Put.name).Replace('{ext}', $e)
            type  = $Put.type
            value = ([string]$Put.value).Replace('{ext}', $e)
        }
    }
    return $out
}

# 一个开关（optimize.registry 的一项）-> 扁平写入动作列表
function Get-RegistryActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Item, [Parameter(Mandatory)] [string[]] $Extensions)
    $out = @()
    $i = 0
    foreach ($raw in @($Item.puts)) {
        $i++
        $put = ConvertTo-RegPut -Put $raw -Where "registry.$($Item.name)[$i]"
        $out += Expand-RegPut -Put $put -Extensions $Extensions
    }
    return $out
}

# 写 .cmd 用「UTF-8 无 BOM + CRLF」：cmd.exe 读批处理时按当前代码页解码，
# 文件首行 chcp 65001 之后的行就会按 UTF-8 解 → 中文不乱码（有 BOM 反而会坏首行）。
function Write-Cmd([string] $Path, [string] $Text) {
    $t = ($Text -replace "`r?`n", "`r`n")
    [IO.File]::WriteAllText($Path, $t, (New-Object Text.UTF8Encoding($false)))
}

# ---- 静默安装参数：按「安装器类型」判定，判不出就报错 ----
#   刻意不写成一个默认值 —— 猜错参数的结果是目标系统上弹出图形安装向导，
#   而不是失败，这种"看起来成功"的坏结果最难发现。
function Get-SilentArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [System.IO.FileInfo] $File)
    $head = [IO.File]::ReadAllBytes($File.FullName)[0..([Math]::Min(1MB, $File.Length - 1))]
    $text = [Text.Encoding]::ASCII.GetString($head)
    # 已知具名例外：命中即采用其已验证参数，且必须先于下方启发式头检测 ——
    # 否则 NSIS/Inno 打包的已知安装器会被头检测抢先、用错静默参数（例如 VC++ 2010 的
    # vcredist_*.exe 是 NSIS 包，头检测会误给 /S 而非官方 /q /norestart，导致首启装失败）。
    if ($Name -match '^7z') { return '/S' }                                        # 7-Zip（NSIS，精简包可能无 Nullsoft 标记）
    if ($Name -match 'vc_redist|vc14') { return '/install /quiet /norestart' }     # VC++ 2015-2022
    if ($Name -match 'vcredist') { return '/q /norestart' }                         # VC++ 2010（vcredist_x86/x64.exe）
    if ($Name -match 'dotnet|windowsdesktop') { return '/install /quiet /norestart' }  # .NET 运行时
    if ($Name -match 'directx|dxruntime') {
        # Jun2010 自解包：先 /Q /C /T: 解出 DXSETUP.exe 到子目录，再静默装（/silent 不弹 EULA）
        $dx = '%SystemDrive%\Tools\install\dx'
        return "/Q /C /T:`"$dx`" && `"$dx\DXSETUP.exe`" /silent /norestart"
    }
    # 启发式头检测：仅对上面没认出的 .exe 生效
    if ($text -match 'Inno Setup') {
        # Inno Setup 官方命令行文档：/VERYSILENT 无 UI，/SP- 去掉启动提示，
        # /SUPPRESSMSGBOXES 抑制对话框，/NORESTART 不重启
        return '/VERYSILENT /SP- /SUPPRESSMSGBOXES /NORESTART'
    }
    if ($text -match 'Nullsoft') {
        # NSIS：/S 静默（**必须大写**）
        return '/S'
    }
    throw "components.$Name 是 .exe 但认不出安装器类型（Inno/NSIS/已知具名），无法确定静默参数 —— 请显式补一条规则，别用猜的"
}

# ---- 把组件静默安装写进应答文件（synthesize pass）----
#   [为什么用应答文件] 安装器（Inno/NSIS/MSI）**没有任何官方途径**能在构建期直接注入镜像内部：
#   DISM 只吃 .cab/.msu。所以「离线集成」的可行落点是：构建期把命令行写进镜像里 Windows 自带的
#   应答机制，装完首次开机由系统自己跑一遍 → 落到 C:\Program Files 的正常安装（可用、可卸载、
#   有「应用和功能」条目），并在跑完后自删应答文件，机器上不留自建脚本。
#   [为什么不是「首启脚本」] 不是我们塞的常驻脚本/计划任务，是 Windows 自己的 unattend 机制；
#   内容仅存在于 %SystemRoot%\Panther\unattend.xml，执行完即由 cmd 自删。
function Write-InstallUnattend {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkDir, [Parameter(Mandatory)] [string[]] $Commands)
    $esc = { param($s) $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
    $p = '%SystemDrive%\Tools\install'
    # [必须] RunSynchronous 的工作目录是 %SystemRoot%\System32，不是载荷目录 ——
    #        直接写 "7z2603-x64.exe" /S 会找不到文件（失败还很安静）。
    #        故每条都先 `cd /d "%SystemDrive%\Tools\install" && …`，用 && 保证 cd 失败就不执行安装。
    $all = @($Commands | ForEach-Object { "cmd.exe /c cd /d `"$p`" && $_" })
    # 收尾自删：应答文件 + 载荷目录都不留在成品机上
    $all += "cmd.exe /c del /f /q `"%SystemRoot%\Panther\unattend.xml`" & rd /s /q `"$p`""
    $items = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        # Order 必须**从 1 递增**且唯一，否则 Windows 只认第一条
        $desc = if ($i -lt $Commands.Count) { 'Install bundled components' } else { 'Clean up unattend and payload' }
        $items += "        <SynchronousCommand wcm:action=`"add`">`r`n" +
                  "          <Order>$($i + 1)</Order>`r`n" +
                  "          <CommandLine>$(& $esc $all[$i])</CommandLine>`r`n" +
                  "          <Description>$desc</Description>`r`n" +
                  "        </SynchronousCommand>"
    }
    # [必须] xmlns:wcm 声明在**组件段自己的 <component> 上**，不能靠根节点：
    #        基础模板的根节点只有默认命名空间，而它各个 <component> 都是各自声明的
    #        （见 config\unattend.xml 第 18/24/30 行）。这里保持同一风格 ——
    #        声明挂在自己身上，合并进任何根节点都合法。
    #        实测教训：漏了这个声明，[xml] 强转会报 "wcm 是未声明的前缀"，
    #        整份应答文件非法、Windows 直接拒收。
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <settings pass="synthesize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <RunSynchronous>
$($items -join "`r`n")
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"@
    # 出站是 UTF-8 带 BOM（.NET 无法生成 UTF-16LE；XML 声明 utf-8 与之自洽）
    [IO.File]::WriteAllText((Join-Path $WorkDir 'config\unattend-components.xml'),
                            $xml, (New-Object Text.UTF8Encoding($true)))
}

$cfg = Get-Content (Join-Path $WorkDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'

$HIVES = @{
    SYSTEM   = @{ file = Join-Path $mount 'Windows\System32\config\SYSTEM';   key = 'HKLM\LTSC_SYS' }
    SOFTWARE = @{ file = Join-Path $mount 'Windows\System32\config\SOFTWARE'; key = 'HKLM\LTSC_SW'  }
    DEFAULT  = @{ file = Join-Path $mount 'Users\Default\NTUSER.DAT';          key = 'HKLM\LTSC_DEF' }
}

if (Test-Path $mount) {
    # [坑] 目录存在 ≠ 仍是挂载点；对非挂载点 Dismount 会抛终止性 COMException
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
    catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
Log "已挂载 install.wim -> $mount"

try {
    # ---------- 1) Set-Edition：转到目标 SKU（本轮目标 = IoT Enterprise LTSC） ----------
    $edition = [string]$cfg.branches.$BranchId.edition
    if (-not $edition) { throw "config.json 缺 branches.$BranchId.edition" }
    $gvlk = [string]$cfg.gvlk.$edition
    if (-not $gvlk) { throw "config.json 的 gvlk 表里没有 $edition（没密钥转不了 SKU）" }
    $curEd = [regex]::Match((dism.exe /English /Image:$mount /Get-CurrentEdition | Out-String),
                            'Current Edition\s*:\s*(\S+)').Groups[1].Value
    if ($curEd -eq $edition) {
        Log "当前已是 $edition，跳过 Set-Edition"
    } else {
        Log "Set-Edition: $curEd -> $edition"
        dism.exe /English /Image:$mount /Set-Edition:$edition /ProductKey:$gvlk /AcceptEula
        if ($LASTEXITCODE -ne 0) { throw "Set-Edition 失败（DISM 退出码 $LASTEXITCODE）：$curEd -> $edition" }
        $now = [regex]::Match((dism.exe /English /Image:$mount /Get-CurrentEdition | Out-String),
                              'Current Edition\s*:\s*(\S+)').Groups[1].Value
        if ($now -ne $edition) { throw "Set-Edition 后复检不符：期望 $edition 实际 $now" }
        Log "Set-Edition 完成，当前 SKU = $now"
    }

    # ---------- 2) 离线优化注入（optimize.registry：config 写了就写）----------
    #   数据全部来自 config.json（由 config-to-json.py 从 config.yml 拍平），代码里不硬编码名单
    $regItems = @($cfg.optimize.registry)
    # [坑] 必须显式 --%[] 或先取成数组再逐项转字符串：JSON 数组经 ConvertFrom-Json 后是 Object[]，
    #      直接 @() 包一层在「只有 1 个元素」时会被 PS 解包成标量，导致参数绑定失败。
    $extList  = @()
    foreach ($e in $cfg.optimize.extensions) { $extList += [string]$e }
    Log "optimize.ini（上游开关，由 99 写入）$(@($cfg.optimize.ini).Count) 项"
    Log "optimize.registry（离线 hive 注入）$($regItems.Count) 项；展开取值 $($extList.Count) 个"

    if ($regItems.Count -gt 0) {
        # 先算 hive 需求前摊平，顺便把解析错误在写之前全部暴露出来
        $allPuts = @()
        foreach ($item in $regItems) {
            $acts = @(Get-RegistryActions -Item $item -Extensions $extList)
            if ($acts.Count -eq 0) { throw "registry.$($item.name) 展开后没有任何写入 —— 配置写空了" }
            foreach ($a in $acts) {
                if ($HIVES.Keys -notcontains $a.hive) {
                    throw "registry.$($item.name) 指定了未知 hive '$($a.hive)'（只支持 $($HIVES.Keys -join ' / ')）"
                }
            }
            $allPuts += $acts
        }
        Log "展开后共 $($allPuts.Count) 条注册表写入"

        $needHives = @($allPuts | ForEach-Object { $_.hive } | Select-Object -Unique)
        foreach ($h in $needHives) {
            $e = $HIVES[$h]
            if (-not (Test-Path $e.file)) { throw "缺少 hive 文件: $($e.file)" }
            & reg.exe load $e.key $e.file | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg load 失败: $($e.key) <- $($e.file)" }
            Log "已加载 hive $h -> $($e.key)"
        }
        try {
            foreach ($m in $allPuts) {
                $e = $HIVES[$m.hive]
                $paths = @()
                if ($m.path -like '*{CS}*') {
                    $cs = @(Get-ChildItem "HKLM:\$($e.key)" -ErrorAction SilentlyContinue |
                            ForEach-Object { $_.PSChildName } | Where-Object { $_ -match '^ControlSet\d+$' })
                    if ($cs.Count -eq 0) { throw "hive $($m.hive) 里找不到 ControlSetNNN，无法写入 $($m.path)" }
                    foreach ($c in $cs) { $paths += ($m.path -replace '\{CS\}', $c) }
                } else {
                    $paths += $m.path
                }
                foreach ($p in $paths) {
                    $rk = "$($e.key)\$p"
                    if ($m.name -eq '') { & reg.exe add $rk /ve /t $m.type /d "$($m.value)" /f | Out-Null }
                    else                { & reg.exe add $rk /v $m.name /t $m.type /d "$($m.value)" /f | Out-Null }
                    if ($LASTEXITCODE -ne 0) { throw "reg add 失败: $rk\$($m.name)=$($m.value)" }
                    $leaf = if ($m.name -eq '') { '(默认)' } else { $m.name }
                    Log "  [opt] $rk  $leaf = $($m.value)"
                }
            }
        } finally {
            foreach ($h in $needHives) { & reg.exe unload $HIVES[$h].key 2>$null | Out-Null }
            Log "hive 已卸载"
        }
    }

    # ---------- 3) 应答文件（延后到 4b 之后合并，见 5）----------

    # ---------- 4) C:\Tools（唯一自建目录，只烤入不自动跑）----------
    $tools = Join-Path $mount 'Tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null

    # 4a) MAS 激活工具包
    $masSrc = Join-Path $WorkDir 'assets\mas'
    $masFiles = @(Get-ChildItem $masSrc -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    if ($masFiles.Count -gt 0) {
        $masDst = Join-Path $tools 'MAS'
        New-Item -ItemType Directory -Force -Path $masDst | Out-Null
        Copy-Item (Join-Path $masSrc '*') $masDst -Recurse -Force
        Get-ChildItem $masDst -Recurse -Force -Filter '.gitkeep' -ErrorAction SilentlyContinue | Remove-Item -Force
        Write-Cmd (Join-Path $tools '激活系统.cmd') @'
@echo off
chcp 65001 >nul
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
cd /d "%~dp0MAS"
if exist "MAS_AIO.cmd" (
    call "MAS_AIO.cmd"
    goto :end
)
if exist "MAS_AIO.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "MAS_AIO.ps1"
    goto :end
)
echo [!] 未找到 MAS 入口（MAS_AIO.cmd / MAS_AIO.ps1）
echo     请手动运行本目录 MAS\ 下的脚本
:end
pause
'@
        Log "MAS 工具包 -> C:\Tools\MAS（$($masFiles.Count) 个文件）；入口 C:\Tools\激活系统.cmd（不自动运行）"
    } else {
        Log "assets\mas 为空 -> 不生成激活入口（放入 MAS 工具包后重新构建即可）"
    }

    # 4b) 组件载荷（optimize.components 声明的那些）
    #     安装器走**应答文件 synthesize pass 的 RunSynchronous** 静默安装，装到各自官方默认目录：
    #       · 7-Zip  官方 FAQ：/S 静默、/D= 指定目录（**大小写敏感**）；x64 exe 默认 C:\Program Files\7-Zip
    #       · MPC-BE 是 Inno Setup 6.7；官方 iss：DefaultDirName={pf}\MPC-BE x64
    #                → x64 安装器里 {pf} = C:\Program Files（ArchitecturesInstallIn64BitMode=x64）
    #       · NDM（实测 Inno 5.5.7）默认 C:\Program Files (x86)\Neat Download Manager
    #       默认路径本就是「64 位程序进 64 位目录 / 该进 x86 的进 x86」，故不传目录参数，全用官方默认。
    #     [为什么不用首启脚本] 这是 Windows 自己的应答机制（unattend.xml synthesize），
    #       不是我们往系统里塞的常驻脚本；跑完由 cmd 自删，机器上不留任何自建代码。
    $redistSrc = Join-Path $WorkDir 'assets\redist'
    $redistFiles = @(Get-ChildItem $redistSrc -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $cmds = @()
    $keys = @($cfg.optimize.components.PSObject.Properties.Name)
    if ($redistFiles.Count -gt 0) {
        # 安装次序：x86 先于 x64（其余保持 config 里写的顺序）
        $ordered = @(@($keys | Where-Object { $_ -match 'x86|32' }) + @($keys | Where-Object { $_ -notmatch 'x86|32' }))
        foreach ($k in $ordered) {
            $f = $redistFiles | Where-Object { $_.Name -like "$k.*" } | Select-Object -First 1
            if (-not $f) { Log "WARN components.$k 的载荷文件不在 assets\redist 下，跳过"; continue }
            switch ($f.Extension.ToLowerInvariant()) {
                '.msi' {
                    # MSI 默认装进 Program Files（x64 包进 64 位目录），无需指定
                    $cmds += ('msiexec /i "{0}" /qn /norestart' -f $f.Name)
                    Log "组件 $k -> $($f.Name)（静默安装，msiexec）"
                }
                '.exe' {
                    # 静默开关按安装器类型区分 —— 认不出就报错，绝不猜参数
                    $sw = Get-SilentArgs -Name $k -File $f
                    $cmds += ('"{0}" {1}' -f $f.Name, $sw)
                    Log "组件 $k -> $($f.Name)（静默安装：$sw）"
                }
                default { throw "components.$k 的载荷 $($f.Name) 不是安装包（只支持 .exe / .msi；便携包请自行放 assets\redist 并改用解包逻辑）" }
            }
        }
    } else {
        Log "assets\redist 为空 -> 无组件安装载荷"
    }

    # 4c) 覆盖文件（assets\overwrite\）：把「某安装器装完之后才存在」的文件替换掉
    #   [为什么需要] 有些组件官方包没有中文，汉化做法是拿改好的主程序覆盖同名文件 ——
    #   但构建期目标文件还不存在（要等首次开机装完），所以只能在应答里**紧跟安装之后**补一条 copy。
    #   [为什么是通用规则] 这里不含任何具体文件名：放什么文件就覆盖什么，相对目录结构原样保留。
    #   目标安装目录走「已核实过的官方默认路径」映射表（见下面 switch）—— 未知组件直接报错，绝不猜。
    #   用法：delta\assets\overwrite\<组件名>\<目标子路径>\<文件>
    #         例 assets\overwrite\ndm\NeatDM.exe → 覆盖 %ProgramFiles(x86)%\Neat Download Manager\NeatDM.exe
    #   目录名必须是 optimize.components 里有的组件名（否则报错，不静默忽略）。
    $owSrc = Join-Path $WorkDir 'assets\overwrite'
    $owDirs = @(Get-ChildItem $owSrc -Directory -ErrorAction SilentlyContinue)
    if ($owDirs.Count -gt 0) {
        $payloadDst = Join-Path $tools 'install'
        foreach ($d in $owDirs) {
            $ck = $d.Name
            if ($keys -notcontains $ck) {
                throw "assets\overwrite\$ck 的目录名不是 optimize.components 里的组件（现有: $($keys -join ', ')）"
            }
            if (($redistFiles | Where-Object { $_.Name -like "$ck.*" }).Count -eq 0) {
                throw "assets\overwrite\$ck 有覆盖文件，但该组件的安装器载荷不在 assets\redist 下 —— 先装后覆盖，缺前者无从谈起"
            }
            $files = @(Get-ChildItem $d.FullName -File -Recurse -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) { Log "assets\overwrite\$ck 为空 -> 跳过"; continue }
            $sub = "ow_$ck"
            $dstDir = Join-Path $payloadDst $sub
            New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
            $copies = @()
            foreach ($f in $files) {
                # 保持相对目录结构（目标子路径 = 相对 overwrite\<组件>\ 的那一段）
                $rel = $f.FullName.Substring($d.FullName.Length).TrimStart('\')
                $toDst = Join-Path $dstDir $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $toDst -Parent) | Out-Null
                Copy-Item $f.FullName $toDst -Force
                $copies += $rel
            }
            # 目标安装目录：按安装器默认路径推 —— 这里只认「已核实过的默认目录」，
            # 未知组件不猜（猜错就是把文件拷到不存在的位置，且失败无声）。
            $defaultDir = switch -Regex ($ck) {
                '^ndm'   { '%ProgramFiles(x86)%\Neat Download Manager' }
                '^7z'    { '%ProgramFiles%\7-Zip' }
                '^mpcbe' { '%ProgramFiles%\MPC-BE x64' }
                default  { $null }
            }
            if (-not $defaultDir) {
                throw "assets\overwrite\$ck：不知道 $ck 的官方默认安装目录，无法生成覆盖命令 —— 请在 07 里补一条映射（别用猜的）"
            }
            foreach ($rel in $copies) {
                # cd 到载荷目录后再 copy（RunSynchronous 的 cwd 是 System32，见 Write-InstallUnattend 说明）
                $cmds += ('if exist "{0}\{1}" copy /y "{2}\{1}" "{0}\{1}"' -f `
                          $defaultDir, $rel, "$sub")
            }
            Log "覆盖文件 $ck -> $($copies.Count) 个（目标 $defaultDir）；已排入应答，紧跟安装之后执行"
        }
    }

    if ($cmds.Count -gt 0) {
        # 载荷跟着进镜像（应答执行时要从这里读）
        $payloadDst = Join-Path $tools 'install'
        New-Item -ItemType Directory -Force -Path $payloadDst | Out-Null
        foreach ($k in $keys) {
            $f = $redistFiles | Where-Object { $_.Name -like "$k.*" } | Select-Object -First 1
            if ($f) { Copy-Item $f.FullName $payloadDst -Force }
        }
        # 直接传「安装/覆盖动作」，cd 与 cmd 包装由 Write-InstallUnattend 统一加
        Write-InstallUnattend -WorkDir $WorkDir -Commands $cmds
        Log "组件静默安装 + 覆盖已写进应答（$($cmds.Count) 条命令）；载荷 C:\Tools\install\；首次开机执行后自删"
    } else {
        Log "无组件安装与覆盖 -> 不生成组件段"
    }

    # ---------- 5) 应答文件烤入（基础 + 组件，合一份）----------
    #   基础项（区域/时区/OOBE）来自 config\unattend.xml，组件静默安装来自 4b 生成的
    #   unattend-components.xml。两份 <settings> 的 pass 不同（specialize/oobeSystem 与
    #   synthesize），根节点相同 → 直接取后者「根节点之后」的内容拼进前者即可，不需要 XML 库。
    $panther = Join-Path $mount 'Windows\Panther'
    New-Item -ItemType Directory -Force -Path $panther | Out-Null
    $baseXml = Get-Content (Join-Path $WorkDir 'config\unattend.xml') -Raw -Encoding UTF8
    $tail = ''
    $compFile = Join-Path $WorkDir 'config\unattend-components.xml'
    if (Test-Path $compFile) {
        $compXml = Get-Content $compFile -Raw -Encoding UTF8
        # 去掉 XML 声明 + 注释 + <unattend ...> 开标签 + </unattend> 收标签 = 纯 settings 段
        # 组件段的 <component> 自带 xmlns:wcm 声明，故无需动基础模板的根节点
        $tail = ($compXml -replace '(?s)^.*?<unattend[^>]*>', '' -replace '(?s)</unattend>\s*$', '').Trim()
        Log "应答合并：基础项 + 组件静默安装（$(([regex]::Matches($tail,'<SynchronousCommand')).Count) 条命令）"
    } else {
        Log "应答合并：仅基础项（无组件安装）"
    }
    $merged = $baseXml -replace '(?s)</unattend>\s*$', ($tail + "`r`n</unattend>`r`n")
    # 构建期就把合并结果按 XML 解析一遍 —— 未声明前缀之类的问题在这里炸掉，
    # 而不是等装机时 Windows 静默忽略整份应答（那种失败没人看得见）
    $null = [xml]$merged
    [IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'), $merged, (New-Object Text.UTF8Encoding($false)))
    Log "烤入 unattend.xml -> $panther（XML 校验通过）"

    Dismount-WindowsImage -Path $mount -Save | Out-Null
    Log "== 镜像烤入完成 =="
} catch {
    Log "FAIL $($_.Exception.Message)"
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null } catch { }
    throw
}

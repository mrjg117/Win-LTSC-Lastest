<#
.SYNOPSIS 07 - 烤入镜像（SKU 转 IoT + 离线优化注入 + 应答 + C:\Tools）
.DESCRIPTION 挂载 install.wim，在一次挂载会话里做完四件事，收尾只 Dismount -Save 一次：
             1) Set-Edition     目标 SKU 取 config.json 的 branches.<分支>.edition，
                                 密钥取 gvlk 表（DISM /Set-Edition 用官方 GVLK）
             2) 离线优化注入    optimize 列表里的「组 B」项直接写目标 hive
                                 （SYSTEM / SOFTWARE / Users\Default\NTUSER.DAT）
                                 装完第一次开机就是改好的 —— 不依赖任何首启脚本
             3) 应答文件        config\unattend.xml -> C:\Windows\Panther\unattend.xml
             4) C:\Tools\       目标系统上唯一的自建目录：
                                   激活系统.cmd  /  MAS\
                                   安装运行库.cmd /  redist\
                                都只烤入、不自动跑；用不用、什么时候用由你决定。

   [为什么组件走 C:\Tools 而不是注入镜像]
   DISM /Add-Package 只接受 .cab/.msu，而 VC++ 可再发行包是 MSI/exe —— 官方口径明确
   不能这样离线集成；唯一官方途径是部署后静默安装（vc_redist.x64.exe /install /quiet
   /norestart）。所以把它烤进 C:\Tools 并附一键入口，按需手动执行，不假称「已集成」。

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

# ---- 组 B：优化项 -> 目标 hive / 键 / 类型 / 值 ----
#   {CS} 占位符 = 该 hive 里所有 ControlSetNNN
#   键的写法与 tools/config-to-json.py 的 OPT_HIVE 名单必须一一对应
$OPT = @{
    disable_hibernate      = @{ h='SYSTEM';   p='{CS}\Control\Power';                                          n='HibernateEnabled';                t='REG_DWORD'; v=0 }
    disable_faststartup    = @{ h='SYSTEM';   p='{CS}\Control\Session Manager\Power';                           n='HiberbootEnabled';                t='REG_DWORD'; v=0 }
    no_bitlocker_auto      = @{ h='SYSTEM';   p='{CS}\Control\BitLocker';                                       n='PreventDeviceEncryption';         t='REG_DWORD'; v=1 }
    disable_telemetry      = @{ h='SOFTWARE'; p='Policies\Microsoft\Windows\DataCollection';                    n='AllowTelemetry';                  t='REG_DWORD'; v=0 }
    no_feedback            = @{ h='SOFTWARE'; p='Policies\Microsoft\Windows\DataCollection';                    n='DoNotShowFeedbackNotifications';  t='REG_DWORD'; v=1 }
    no_consumer_features   = @{ h='SOFTWARE'; p='Policies\Microsoft\Windows\CloudContent';                      n='DisableWindowsConsumerFeatures';  t='REG_DWORD'; v=1 }
    no_spotlight           = @{ h='SOFTWARE'; p='Policies\Microsoft\Windows\CloudContent';                      n='DisableWindowsSpotlightFeatures'; t='REG_DWORD'; v=1 }
    no_advertising_id      = @{ h='SOFTWARE'; p='Policies\Microsoft\Windows\AdvertisingInfo';                   n='DisabledByGroupPolicy';           t='REG_DWORD'; v=1 }
    allow_all_trusted_apps = @{ h='SOFTWARE'; p='Policies\Microsoft\Windows\Appx';                              n='AllowAllTrustedApps';             t='REG_DWORD'; v=1 }
    show_file_extensions   = @{ h='DEFAULT';  p='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';  n='HideFileExt';                     t='REG_DWORD'; v=0 }
    show_hidden_files      = @{ h='DEFAULT';  p='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';  n='Hidden';                          t='REG_DWORD'; v=1 }
    taskbar_align_left     = @{ h='DEFAULT';  p='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';  n='TaskbarAl';                       t='REG_DWORD'; v=0 }
    numlock_on             = @{ h='DEFAULT';  p='Control Panel\Keyboard';                                       n='InitialKeyboardIndicators';       t='REG_SZ';    v='2' }
    classic_context_menu   = @{ h='DEFAULT';  p='Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; n=''; t='REG_SZ';         v='' }
}

# 写 .cmd 用「UTF-8 无 BOM + CRLF」：cmd.exe 读批处理时按当前代码页解码，
# 文件首行 chcp 65001 之后的行就会按 UTF-8 解 → 中文不乱码（有 BOM 反而会坏首行）。
function Write-Cmd([string] $Path, [string] $Text) {
    $t = ($Text -replace "`r?`n", "`r`n")
    [IO.File]::WriteAllText($Path, $t, (New-Object Text.UTF8Encoding($false)))
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

    # ---------- 2) 离线优化注入（组 B）----------
    $wanted  = @($cfg.optimize_hive)
    $iniOnly = @($cfg.optimize_ini)
    # 组别由 tools/config-to-json.py 一处判好；这里只校验「被判为离线注入的项在本脚本表里都有实现」
    $noImpl = @($wanted | Where-Object { -not $OPT.ContainsKey($_) })
    if ($noImpl.Count -gt 0) {
        throw "optimize 里的 $($noImpl -join ', ') 被判为离线注入项，但 07.Bake-Image 的 OPT 表里没有实现"
    }
    Log "optimize 组 A（上游 ini，由 99 写入）$($iniOnly.Count) 项 -> $($iniOnly -join ',')"
    Log "optimize 组 B（离线注入）$($wanted.Count) 项 -> $($wanted -join ',')"

    if ($wanted.Count -gt 0) {
        $needHives = @($wanted | ForEach-Object { $OPT[$_].h } | Select-Object -Unique)
        foreach ($h in $needHives) {
            $e = $HIVES[$h]
            if (-not (Test-Path $e.file)) { throw "缺少 hive 文件: $($e.file)" }
            & reg.exe load $e.key $e.file | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg load 失败: $($e.key) <- $($e.file)" }
            Log "已加载 hive $h -> $($e.key)"
        }
        try {
            foreach ($name in $wanted) {
                $m = $OPT[$name]
                $e = $HIVES[$m.h]
                $paths = @()
                if ($m.p -like '*{CS}*') {
                    $cs = @(Get-ChildItem "HKLM:\$($e.key)" -ErrorAction SilentlyContinue |
                            ForEach-Object { $_.PSChildName } | Where-Object { $_ -match '^ControlSet\d+$' })
                    if ($cs.Count -eq 0) { throw "hive $($m.h) 里找不到 ControlSetNNN，无法写入 $name" }
                    foreach ($c in $cs) { $paths += ($m.p -replace '\{CS\}', $c) }
                } else {
                    $paths += $m.p
                }
                foreach ($p in $paths) {
                    $rk = "$($e.key)\$p"
                    if ($m.n -eq '') { & reg.exe add $rk /ve /t $m.t /d "$($m.v)" /f | Out-Null }
                    else             { & reg.exe add $rk /v $m.n /t $m.t /d "$($m.v)" /f | Out-Null }
                    if ($LASTEXITCODE -ne 0) { throw "reg add 失败: $rk\$($m.n)=$($m.v)" }
                    Log "  [opt] $name -> $rk  $($m.n)=$($m.v)"
                }
            }
        } finally {
            foreach ($h in $needHives) { & reg.exe unload $HIVES[$h].key 2>$null | Out-Null }
            Log "hive 已卸载"
        }
    }

    # ---------- 3) 应答文件 ----------
    $panther = Join-Path $mount 'Windows\Panther'
    New-Item -ItemType Directory -Force -Path $panther | Out-Null
    Copy-Item (Join-Path $WorkDir 'config\unattend.xml') (Join-Path $panther 'unattend.xml') -Force
    Log "烤入 unattend.xml -> $panther"

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

    # 4b) 组件载荷（config.components 声明的那些）
    $redistSrc = Join-Path $WorkDir 'assets\redist'
    $redistFiles = @(Get-ChildItem $redistSrc -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    if ($redistFiles.Count -gt 0) {
        $redistDst = Join-Path $tools 'redist'
        New-Item -ItemType Directory -Force -Path $redistDst | Out-Null
        # 安装次序：x86 先于 x64（其余保持 config 里写的顺序）
        $keys = @($cfg.components.PSObject.Properties.Name)
        $ordered = @(@($keys | Where-Object { $_ -match 'x86|32' }) + @($keys | Where-Object { $_ -notmatch 'x86|32' }))
        $lines = @()
        foreach ($k in $ordered) {
            $f = $redistFiles | Where-Object { $_.Name -like "$k.*" } | Select-Object -First 1
            if (-not $f) { Log "WARN components.$k 的载荷文件不在 assets\redist 下，跳过"; continue }
            Copy-Item $f.FullName $redistDst -Force
            $lines += ('"{0}" /install /quiet /norestart' -f $f.Name)
        }
        if ($lines.Count -gt 0) {
            $body = "@echo off`nchcp 65001 >nul`nnet session >nul 2>&1`n" +
                    "if not ""%errorlevel%""==""0"" (`n" +
                    "    powershell -NoProfile -Command ""Start-Process -Verb RunAs -FilePath '%~f0'""`n" +
                    "    exit /b`n)`ncd /d ""%~dp0redist""`necho 正在安装组件（静默，顺序如下）...`n" +
                    (($lines | ForEach-Object { "echo   $_" }) -join "`n") + "`n" +
                    ($lines -join "`n") + "`necho 完成。`npause`n"
            Write-Cmd (Join-Path $tools '安装运行库.cmd') $body
            Log "组件载荷 -> C:\Tools\redist（$($lines.Count) 个）；入口 C:\Tools\安装运行库.cmd（不自动运行）"
        }
    } else {
        Log "assets\redist 为空 -> 不生成组件安装入口"
    }

    Dismount-WindowsImage -Path $mount -Save | Out-Null
    Log "== 镜像烤入完成 =="
} catch {
    Log "FAIL $($_.Exception.Message)"
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null } catch { }
    throw
}

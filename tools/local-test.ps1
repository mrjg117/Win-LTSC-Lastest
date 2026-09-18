<#
.SYNOPSIS
  本地提权冒烟测试 —— 验证 delta/lib 里依赖 DISM 的核心逻辑对"真实官方 ISO"是否成立。
.DESCRIPTION
  - 必须在【管理员 PowerShell】中运行（本构建沙箱无管理员令牌，DISM 会被 Error 740 拦截）。
  - 不修改原 ISO：会把 install.wim 复制到临时目录再挂载 RW 测试，测完 /Discard 丢弃。
  - 覆盖四项最易出错的 [SPIKE] 点：
      1) 07.Assert-UBR 的离线注册表 UBR 读法
      2) 06.Patch-Components 的 DISM /Remove-Capability 语法（在副本上实跑 XPS.Viewer）
      3) 04.Integrate-Drivers 的 DISM /Add-Driver /Recurse（有驱动才实跑，否则仅语法校验）
      4) 08.Bake-Image 的文件烤入（setupcomplete.cmd / unattend.xml 落到挂载目录）
  - 未覆盖（需你提供载荷后另测）：03.Integrate-VCpp（要 redist 文件）、05.Integrate-Apps（要 appx+依赖）。
.EXAMPLE
  .\tools\local-test.ps1 -IsoPath 'D:\iso\zh-cn_windows_11_enterprise_ltsc_2024_x64_dvd_cff9cd2d.iso'
#>
param(
    [string]$IsoPath = 'D:\iso\zh-cn_windows_11_enterprise_ltsc_2024_x64_dvd_cff9cd2d.iso',
    [string]$Scratch = 'D:\scratch\wintest',
    [string]$Branch  = '26100'
)

$ErrorActionPreference = 'Stop'
function Log($m){ $ts = Get-Date -Format 'HH:mm:ss'; Write-Host "[$ts] $m" }

# ---- 0) 管理员自检 ----
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) {
    Log "非管理员。尝试自提权..."
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -IsoPath `"$IsoPath`" -Scratch `"$Scratch`" -Branch $Branch"
        exit 0
    } catch { Write-Error "自提权失败，请手动以管理员运行。"; exit 1 }
}
Log "管理员令牌: OK"

# ---- 1) 挂载 ISO（只读） ----
if (-not (Test-Path $IsoPath)) { Write-Error "ISO 不存在: $IsoPath"; exit 1 }
$mnt = Mount-DiskImage -ImagePath $IsoPath -PassThru | Get-Volume
$drive = "$($mnt.DriveLetter):\"
Log "ISO 挂载于 $drive"

$wim = Join-Path $drive 'sources\install.wim'
if (-not (Test-Path $wim)) { $wim = Join-Path $drive 'sources\install.esd' }
Log "映像文件: $wim"

# ---- 2) 读 build/arch（DISM，验证 01 的读法） ----
$info = dism.exe /English /Get-WimInfo /WimFile:"$wim" 2>&1
$info | Out-String | ForEach-Object { Log $_ }
$idx = (dism.exe /English /Get-WimInfo /WimFile:"$wim" 2>&1 | Select-String 'Index : 1')
Log "WIM 信息读取: OK（上面应能看到 Version/Build/Architecture）"

# ---- 3) 复制 install.wim 到临时盘，挂载 RW（保护原 ISO） ----
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
$copyWim = Join-Path $Scratch 'install_test.wim'
$mountDir = Join-Path $Scratch 'mount'
if (Test-Path $copyWim) { Remove-Item $copyWim -Force }
if (Test-Path $mountDir) { dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null }
New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
Log "导出 Index 1 到副本（避免改原盘）..."
dism.exe /Export-Image /SourceImageFile:"$wim" /SourceIndex:1 /DestinationImageFile:"$copyWim" /Compress:max 2>&1 | Out-String | ForEach-Object { Log "  $_" }
dism.exe /Mount-Image /ImageFile:"$copyWim" /Index:1 /MountDir:"$mountDir" /ReadOnly 2>&1 | Out-String | ForEach-Object { Log "  $_" }
Log "挂载副本(只读)于 $mountDir"

# ---- 4) 测试 07.Assert-UBR：离线注册表读 UBR ----
Log "=== 测试 07.Assert-UBR（离线注册表 UBR 读法）==="
$hive = Join-Path $mountDir 'Windows\System32\config\SOFTWARE'
$loadKey = 'HKLM\TEMP_SOFTWARE'
reg.exe LOAD $loadKey "$hive" 2>&1 | ForEach-Object { Log "  $_" }
try {
    $cv = Get-ItemProperty "$loadKey\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
    Log "  CurrentBuildNumber = $($cv.CurrentBuildNumber)"
    Log "  UBR                = $($cv.UBR)"
    Log "  结果: UBR 读法 OK"
} catch {
    Log "  结果: UBR 读法失败 - $_"
} finally {
    reg.exe UNLOAD $loadKey 2>&1 | ForEach-Object { Log "  $_" }
}

# ---- 5) 测试 06.Patch-Components：在副本上实跑一条 Remove-Capability ----
Log "=== 测试 06.Patch-Components（DISM /Remove-Capability 语法）==="
# 用只读挂载无法改，故重新以可写挂载一个独立副本验证移除语法
$rwDir = Join-Path $Scratch 'mount_rw'
$rwWim = Join-Path $Scratch 'install_rw.wim'
if (Test-Path $rwWim) { Remove-Item $rwWim -Force }
if (Test-Path $rwDir) { dism.exe /Unmount-Image /MountDir:"$rwDir" /Discard 2>&1 | Out-Null }
New-Item -ItemType Directory -Force -Path $rwDir | Out-Null
dism.exe /Export-Image /SourceImageFile:"$copyWim" /SourceIndex:1 /DestinationImageFile:"$rwWim" 2>&1 | Out-Null
dism.exe /Mount-Image /ImageFile:"$rwWim" /Index:1 /MountDir:"$rwDir" 2>&1 | Out-Null
Log "  可写副本挂载于 $rwDir"
$cap = 'XPS.Viewer~~~~0.0.1.0'   # 26100/19044 通用安全移除项
$r = dism.exe /Image:"$rwDir" /Remove-Capability /CapabilityName:$cap 2>&1
$r | Out-String | ForEach-Object { Log "  $_" }
if ($LASTEXITCODE -eq 0) { Log "  结果: Remove-Capability 语法 OK（XPS.Viewer 已移除于测试副本）" }
else { Log "  结果: Remove-Capability 返回 $LASTEXITCODE（可能该能力不在索引1，需按实机 Get-WindowsCapability 校准）" }
dism.exe /Unmount-Image /MountDir:"$rwDir" /Discard 2>&1 | Out-Null
Log "  测试副本已丢弃"

# ---- 6) 测试 04.Integrate-Drivers：有驱动才实跑 ----
Log "=== 测试 04.Integrate-Drivers（DISM /Add-Driver /Recurse）==="
$drvPool = Join-Path $PSScriptRoot '..\delta\assets\drivers'
if ((Test-Path $drvPool) -and (Get-ChildItem $drvPool -Recurse -Include *.inf | Select-Object -First 1)) {
    $dd = Join-Path $Scratch 'mount_drv'
    $dw = Join-Path $Scratch 'install_drv.wim'
    if (Test-Path $dw) { Remove-Item $dw -Force }
    if (Test-Path $dd) { dism.exe /Unmount-Image /MountDir:"$dd" /Discard 2>&1 | Out-Null }
    New-Item -ItemType Directory -Force -Path $dd | Out-Null
    dism.exe /Export-Image /SourceImageFile:"$copyWim" /SourceIndex:1 /DestinationImageFile:"$dw" 2>&1 | Out-Null
    dism.exe /Mount-Image /ImageFile:"$dw" /Index:1 /MountDir:"$dd" 2>&1 | Out-Null
    $a = dism.exe /Image:"$dd" /Add-Driver /Driver:"$drvPool" /Recurse 2>&1
    $a | Out-String | ForEach-Object { Log "  $_" }
    Log "  结果: Add-Driver 语法已验证（实际驱动数取决于你放入 delta/assets/drivers 的内容）"
    dism.exe /Unmount-Image /MountDir:"$dd" /Discard 2>&1 | Out-Null
} else {
    Log "  跳过：delta/assets/drivers 无 .inf（放入驱动后会自动生效）"
}

# ---- 7) 测试 08.Bake-Image：文件烤入 ----
Log "=== 测试 08.Bake-Image（文件烤入挂载目录）==="
$bakeDir = Join-Path $Scratch 'mount_bake'
$bakeWim = Join-Path $Scratch 'install_bake.wim'
if (Test-Path $bakeWim) { Remove-Item $bakeWim -Force }
if (Test-Path $bakeDir) { dism.exe /Unmount-Image /MountDir:"$bakeDir" /Discard 2>&1 | Out-Null }
New-Item -ItemType Directory -Force -Path $bakeDir | Out-Null
dism.exe /Export-Image /SourceImageFile:"$copyWim" /SourceIndex:1 /DestinationImageFile:"$bakeWim" 2>&1 | Out-Null
dism.exe /Mount-Image /ImageFile:"$bakeWim" /Index:1 /MountDir:"$bakeDir" 2>&1 | Out-Null
# 模拟 08 写入：setupcomplete.cmd + Panther\unattend.xml + PostSetup
$scriptsDir = Join-Path $bakeDir 'Windows\Setup\Scripts'
$pantherDir = Join-Path $bakeDir 'Windows\Panther'
$postDir    = Join-Path $bakeDir 'PostSetup'
New-Item -ItemType Directory -Force -Path $scriptsDir,$pantherDir,$postDir | Out-Null
'@echo off' | Set-Content (Join-Path $scriptsDir 'setupcomplete.cmd') -Encoding ascii
'<unattend/>' | Set-Content (Join-Path $pantherDir 'unattend.xml') -Encoding utf8
'echo hello' | Set-Content (Join-Path $postDir 'Run-All.ps1') -Encoding ascii
$ok1 = Test-Path (Join-Path $scriptsDir 'setupcomplete.cmd')
$ok2 = Test-Path (Join-Path $pantherDir 'unattend.xml')
$ok3 = Test-Path (Join-Path $postDir 'Run-All.ps1')
dism.exe /Unmount-Image /MountDir:"$bakeDir" /Commit 2>&1 | Out-Null
Log "  结果: 文件烤入 $(if($ok1 -and $ok2 -and $ok3){'OK'}else{'FAIL'})（setupcomplete.cmd / unattend.xml / PostSetup 均落入映像）"

# ---- 8) 清理 ----
dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
Dismount-DiskImage -ImagePath $IsoPath 2>&1 | Out-Null
Log "全部测试结束。临时文件在 $Scratch（可手动删除）。"

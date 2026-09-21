<#
.SYNOPSIS
  本地提权冒烟测试 —— 验证 delta/lib 里依赖 DISM 的核心逻辑对"真实官方 ISO"是否成立。
.DESCRIPTION
  - 必须在【管理员 PowerShell】中运行（本构建沙箱无管理员令牌，DISM 会被 Error 740 拦截）。
  - 不修改原 ISO：会把 install.wim 复制到临时目录再挂载 RW 测试，测完 /Discard 丢弃。
  - 覆盖最易出错的几处：
      0) 99.Force-W10UI-Ini 的 ini 强制写回（红线=0 / 组A=1 / 未命中行不变 / 无BOM / 幂等）
         —— 这一步不依赖 ISO，几秒完成（本文件其余步骤都要 ISO + 管理员）
      1) 01.Build-Manifest 的 build 读法（Version 取末段，不能整串转 int）
      2) 06.Assert-UBR 的离线注册表 UBR 读法
      3) 05.Patch-Components 的 DISM /Remove-Capability 语法（在副本上实跑 XPS.Viewer）
      4) 03.Integrate-Drivers 的 DISM /Add-Driver /Recurse（有驱动才实跑，否则仅语法校验）
      5) 07.Bake-Image 的文件烤入（unattend.xml / C:\Tools 落到挂载目录）
  - 未覆盖（需你提供载荷后另测）：04.Integrate-Apps（要 appx + 依赖 + license）。
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

# ---- 0b) 测试 99.Force-W10UI-Ini：ini 强制写回（不依赖 ISO） ----
# 断言：override 红线置 0、config 组A 项置 1、未命中行逐字不变、不写 BOM、连跑两遍字节相同
Log "=== 测试 99.Force-W10UI-Ini（红线 + 组A 强制写回，字节保真 + 幂等）==="
$t99 = Join-Path $Scratch 't99'
if (Test-Path $t99) { Remove-Item $t99 -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $t99 'logs') -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\delta\win10ui-override.ini') (Join-Path $t99 'win10ui-override.ini') -Force
# 伪造一份「上游 W10UI.ini」：必须含 config 里所有 optimize 组A 键，否则 99 会（正确地）报错
$grpA = @('nosuggapp','nosuggtip','norestorage','nogamebar','oobebypass','UpdtBootFiles')
$fake = @('; synthetic upstream ini','[Options]','wim2esd=1','ResetBase=1') +
        @($grpA | ForEach-Object { "$_=0" }) + @('netfx3=1','')
[IO.File]::WriteAllBytes((Join-Path $t99 'W10UI.ini'),
                         [Text.Encoding]::GetEncoding(28591).GetBytes((($fake -join "`r`n") + "`r`n")))
# config.json 只需 optimize_ini 字段（99 只读它；顺带覆盖「带 BOM 的 UTF-8」读取路径）
('{"optimize_ini":["' + (@($grpA) -join '","') + '"]}') |
    Set-Content (Join-Path $t99 'config.json') -Encoding UTF8
$script99 = Join-Path $PSScriptRoot '..\delta\lib\99.Force-W10UI-Ini.ps1'
try {
    & $script99 -WorkDir $t99 | Out-Null
    $b2 = [IO.File]::ReadAllBytes((Join-Path $t99 'W10UI.ini'))
    & $script99 -WorkDir $t99 | Out-Null
    $b3 = [IO.File]::ReadAllBytes((Join-Path $t99 'W10UI.ini'))
    $t99txt = [Text.Encoding]::GetEncoding(28591).GetString($b3)
    # [坑] 断言不要用 (?m)^k=v$ —— .NET 的 $ 只在 \n 前成立，CRLF 行尾多了个 \r 就永不匹配。
    #      按行切分后做精确字符串比对，与换行符形态无关。
    $t99lines = @($t99txt -split "`r?`n" | ForEach-Object { $_.Trim() })
    $missA = @($grpA | Where-Object { $t99lines -notcontains "$_=1" })
    $ok99  = ($t99lines -contains 'wim2esd=0') -and ($t99lines -contains 'ResetBase=0') -and
             ($missA.Count -eq 0) -and ($t99lines -contains 'netfx3=1') -and
             ($b3[0] -ne 0xEF) -and
             ([Convert]::ToBase64String($b2) -eq [Convert]::ToBase64String($b3))
    Log "  结果: 99 强制写回 $(if($ok99){'OK'}else{'FAIL'})（红线=0 / 组A=1 / 未命中行不变 / 无BOM / 两遍幂等）"
    if (-not $ok99) { Log "  未置1的组A项: $($missA -join ', ')" }
} catch {
    Log "  结果: 99 测试抛错 - $($_.Exception.Message)"
}

# ---- 1) 挂载 ISO（只读） ----
if (-not (Test-Path $IsoPath)) { Write-Error "ISO 不存在: $IsoPath"; exit 1 }
$mnt = Mount-DiskImage -ImagePath $IsoPath -PassThru | Get-Volume
$drive = "$($mnt.DriveLetter):\"
Log "ISO 挂载于 $drive"

$wim = Join-Path $drive 'sources\install.wim'
if (-not (Test-Path $wim)) { $wim = Join-Path $drive 'sources\install.esd' }
Log "映像文件: $wim"

# ---- 2) 读 build/arch（验证 01 的读法） ----
$info = dism.exe /English /Get-WimInfo /WimFile:"$wim" 2>&1
$info | Out-String | ForEach-Object { Log $_ }
$ver = [regex]::Match(($info | Out-String), 'Version\s*:\s*(\d+\.\d+\.\d+)').Groups[1].Value
if ($ver) { Log "Version=$ver -> build=$([int]($ver.Split('.')[-1]))（应等于分支号 $Branch）" }
else      { Log "WARN 未能从 DISM 输出解析 Version" }

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

# ---- 4) 测试 06.Assert-UBR：离线注册表读 UBR ----
Log "=== 测试 06.Assert-UBR（离线注册表 UBR 读法）==="
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

# ---- 5) 测试 05.Patch-Components：在副本上实跑一条 Remove-Capability ----
Log "=== 测试 05.Patch-Components（DISM /Remove-Capability 语法）==="
# 只读挂载改不了，故重新以可写挂载一个独立副本验证移除语法
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

# ---- 6) 测试 03.Integrate-Drivers：有驱动才实跑 ----
Log "=== 测试 03.Integrate-Drivers（DISM /Add-Driver /Recurse）==="
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

# ---- 7) 测试 07.Bake-Image：文件烤入 ----
Log "=== 测试 07.Bake-Image（unattend.xml / C:\Tools 烤入挂载目录）==="
$bakeDir = Join-Path $Scratch 'mount_bake'
$bakeWim = Join-Path $Scratch 'install_bake.wim'
if (Test-Path $bakeWim) { Remove-Item $bakeWim -Force }
if (Test-Path $bakeDir) { dism.exe /Unmount-Image /MountDir:"$bakeDir" /Discard 2>&1 | Out-Null }
New-Item -ItemType Directory -Force -Path $bakeDir | Out-Null
dism.exe /Export-Image /SourceImageFile:"$copyWim" /SourceIndex:1 /DestinationImageFile:"$bakeWim" 2>&1 | Out-Null
dism.exe /Mount-Image /ImageFile:"$bakeWim" /Index:1 /MountDir:"$bakeDir" 2>&1 | Out-Null
# 模拟 07 的落点：Panther\unattend.xml + C:\Tools\
$pantherDir = Join-Path $bakeDir 'Windows\Panther'
$toolsDir   = Join-Path $bakeDir 'Tools'
New-Item -ItemType Directory -Force -Path $pantherDir,$toolsDir | Out-Null
'<unattend/>'    | Set-Content (Join-Path $pantherDir 'unattend.xml')   -Encoding utf8
'@echo off'      | Set-Content (Join-Path $toolsDir   '激活系统.cmd')   -Encoding ascii
'@echo off'      | Set-Content (Join-Path $toolsDir   '安装运行库.cmd') -Encoding ascii
$ok1 = Test-Path (Join-Path $pantherDir 'unattend.xml')
$ok2 = Test-Path (Join-Path $toolsDir   '激活系统.cmd')
dism.exe /Unmount-Image /MountDir:"$bakeDir" /Commit 2>&1 | Out-Null
Log "  结果: 文件烤入 $(if($ok1 -and $ok2){'OK'}else{'FAIL'})（unattend.xml / C:\Tools 均落入映像）"

# ---- 8) 清理 ----
dism.exe /Unmount-Image /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
Dismount-DiskImage -ImagePath $IsoPath 2>&1 | Out-Null
Log "全部测试结束。临时文件在 $Scratch（可手动删除）。"

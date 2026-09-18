<#
.SYNOPSIS 05 - 离线 provision 应用（仅 Win11 分支 26100）
.DESCRIPTION 用 DISM /Add-ProvisionedAppxPackage 把 Store/Paint/Notepad/MediaPlayer/nanazip
             烤进映像。每个 appx 需带 license + 框架依赖（Windows App SDK Runtime / VC++）。
             Win10 分支(LTSC 2021/21H2)因 MSIX MinVersion 钉 Windows 11，强行注入会报
             0x80073cfd，故跳过，使用内置经典版。
   [SPIKE] appx/license/依赖需实机用 winget download 或 Store for Business 离线包获取并校准路径。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\05-apps.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

if ($BranchId -ne '26100') {
    Log "非 Win11 分支，跳过应用预装（Win10 用内置经典 Notepad/Paint）"
    return
}

$appsDir = Join-Path $WorkDir 'assets\apps'
if (-not (Test-Path $appsDir)) { Log "无 assets\apps 目录，跳过"; return }

$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'   # [SPIKE] 路径随 W10UI 输出确认
if (Test-Path $mount) {
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
    catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
Log "已挂载 install.wim -> $mount"

# 顺序：Store 本体先（LTSC 默认无），再 Paint/Notepad/MediaPlayer/nanazip
$order = @('Store','Paint','Notepad','MediaPlayer','nanazip')
foreach ($name in $order) {
    $pkg = Join-Path $appsDir "$name*.msixbundle"
    $matches = Get-ChildItem $pkg -ErrorAction SilentlyContinue
    if (-not $matches) { Log "WARN 未找到 $name 包，跳过"; continue }
    $msix = $matches[0].FullName
    $lic  = Get-ChildItem (Join-Path $appsDir "$name*.xml") -ErrorAction SilentlyContinue | Select-Object -First 1
    $deps = (Get-ChildItem (Join-Path $appsDir '*.msix') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Store|Paint|Notepad|MediaPlayer|nanazip' } | ForEach-Object { $_.FullName }) -join ','
    $dargs = @('/Image:' + $mount, '/Add-ProvisionedAppxPackage', '/PackagePath:' + $msix)
    if ($lic) { $dargs += '/LicensePath:' + $lic.FullName }
    if ($deps) { $dargs += '/DependencyPackagePath:' + $deps }
    Log "provision $name -> $msix"
    dism.exe /English @dargs
    if ($LASTEXITCODE -ne 0) { Log "FAIL provision $name"; throw "应用预装失败: $name" }
    Log "OK $name"
}
Dismount-WindowsImage -Path $mount -Save | Out-Null
Log "== 应用预装完成 =="

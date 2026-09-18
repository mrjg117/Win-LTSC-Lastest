<#
.SYNOPSIS 06 - 精简组件（lean profile）
.DESCRIPTION 挂载 install.wim，按 patchlist.json 的 lean 清单：
             T1 Remove-WindowsCapability / Disable-WindowsOptionalFeature；
             T2 移除 IoT Removable Packages（微软官方清单，从组件存储移除不可逆）。
   [SPIKE] 包名/功能名需用 Get-WindowsPackage / Get-WindowsOptionalFeature 在真机校准准确字符串。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\06-lean.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'   # [SPIKE] 路径随 W10UI 输出确认
if (Test-Path $mount) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
Log "已挂载 install.wim -> $mount"

$pl = Get-Content (Join-Path $WorkDir 'patchlist.json') -Raw | ConvertFrom-Json
$lean = $pl.branches.$BranchId.lean

# T1 capability 移除
foreach ($cap in $lean.tier1_remove_capabilities) {
    Log "Remove-Capability $cap"
    dism.exe /Image:$mount /Remove-WindowsCapability /CapabilityName:$cap
    if ($LASTEXITCODE -ne 0) { Log "WARN Remove-Capability 失败: $cap（可能本 SKU 无此组件）" }
}
# T1 可选功能禁用
foreach ($feat in $lean.tier1_disable_features) {
    Log "Disable-Feature $feat"
    dism.exe /Image:$mount /Disable-WindowsOptionalFeature /FeatureName:$feat /Remove
    if ($LASTEXITCODE -ne 0) { Log "WARN Disable-Feature 失败: $feat" }
}
# T2 IoT 深度可移除包
foreach ($pkg in $lean.tier2_remove_packages) {
    Log "Remove-Package $pkg"
    dism.exe /Image:$mount /Remove-Package /PackageName:$pkg
    if ($LASTEXITCODE -ne 0) { Log "WARN Remove-Package 失败: $pkg（确认包名/本 SKU 是否存在）" }
}
Dismount-WindowsImage -Path $mount -Save | Out-Null
Log "== 组件精简完成（WARN 项需在真机用 Get-WindowsPackage 校准包名后清除）=="

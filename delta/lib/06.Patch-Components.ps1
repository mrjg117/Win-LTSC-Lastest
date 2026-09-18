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
if (Test-Path $mount) {
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
    catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
Log "已挂载 install.wim -> $mount"

$pl = Get-Content (Join-Path $WorkDir 'patchlist.json') -Raw | ConvertFrom-Json
$lean = $pl.branches.$BranchId.lean

# T1 capability 移除
# [关键] 离线映像的 DISM 选项是 /Remove-**Capability**（不是 /Remove-WindowsCapability），
#        后者会让 DISM 报 "Error: 87 / The remove-windowscapability option is unknown."
$caps = @()
try { $caps = @(Get-WindowsCapability -Path $mount -ErrorAction Stop) } catch { Log "WARN 枚举 capability 失败: $($_.Exception.Message)" }
foreach ($cap in $lean.tier1_remove_capabilities) {
    $hit = $caps | Where-Object { $_.Name -ieq $cap -and $_.State -eq 'Installed' }
    if (-not $hit) { Log "SKIP capability 未安装/不存在: $cap"; continue }
    Log "Remove-Capability $cap"
    dism.exe /Image:$mount /Remove-Capability /CapabilityName:$cap
    if ($LASTEXITCODE -ne 0) { Log "WARN Remove-Capability 失败: $cap" }
}
# T1 可选功能禁用
foreach ($feat in $lean.tier1_disable_features) {
    Log "Disable-Feature $feat"
    dism.exe /Image:$mount /Disable-WindowsOptionalFeature /FeatureName:$feat /Remove
    if ($LASTEXITCODE -ne 0) { Log "WARN Disable-Feature 失败: $feat" }
}
# T2 IoT 深度可移除包
# [注意] 微软官方 Removable Packages 以 LastDescription... 这些包一旦被累积更新取代，
#        就再也无法从映像中移除（CBS 报 Error 87 / 0x80070057）。故先枚举存在性，
#        不存在即跳过（记 SKIP 而非 WARN），避免日志被必然失败刷屏。
$pkgs = @()
try { $pkgs = @(Get-WindowsPackage -Path $mount -ErrorAction Stop | Select-Object -ExpandProperty PackageName) } catch { Log "WARN 枚举已装包失败: $($_.Exception.Message)" }
foreach ($pkg in $lean.tier2_remove_packages) {
    if ($pkgs -notcontains $pkg) { Log "SKIP 包不存在(或已被更新取代，不可移除): $pkg"; continue }
    Log "Remove-Package $pkg"
    dism.exe /Image:$mount /Remove-Package /PackageName:$pkg
    if ($LASTEXITCODE -ne 0) { Log "WARN Remove-Package 失败: $pkg" }
}
Dismount-WindowsImage -Path $mount -Save | Out-Null
Log "== 组件精简完成（WARN 项需在真机用 Get-WindowsPackage 校准包名后清除）=="

<#
.SYNOPSIS 04 - 驱动注入（留盘，PnP 按需装）
.DESCRIPTION install.wim 全量驱动池：DISM /Add-Driver /Recurse 写进 DriverStore，
             部署时 Windows PnP 只安装硬件匹配的驱动，不匹配的只占存储不加载、不冲突。
             boot.wim 索引2（Setup）注入最小集（存储/RAID/NVMe/网卡），使安装器可见磁盘。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\04-drivers.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'   # [SPIKE] 路径随 W10UI 输出确认

# install.wim 全量驱动池
$pool = Join-Path $WorkDir 'assets\drivers'
if (Test-Path $pool) {
    if (Test-Path $mount) {
        # [坑] 目录存在 ≠ 仍是挂载点；非挂载点 Dismount 会抛终止性 COMException
        try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
        catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
    }
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
    Log "注入驱动池(全量, 留盘): $pool"
    dism.exe /Image:$mount /Add-Driver /Driver:$pool /Recurse /ForceUnsigned
    if ($LASTEXITCODE -ne 0) { Log "FAIL 驱动注入"; throw "驱动注入失败" }
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    Log "install.wim 驱动池注入完成"
}

# boot.wim 最小集
$bootPool = Join-Path $WorkDir 'assets\drivers\boot'
$bootWim = Join-Path $WorkDir 'ISO\sources\boot.wim'
if (Test-Path $bootPool) {
    $mountBoot = Join-Path $WorkDir 'mount_boot'
    if (Test-Path $mountBoot) { Dismount-WindowsImage -Path $mountBoot -Discard -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $mountBoot | Out-Null
    Mount-WindowsImage -ImagePath $bootWim -Index 2 -Path $mountBoot | Out-Null
    Log "注入 boot.wim(索引2) 最小驱动集: $bootPool"
    dism.exe /Image:$mountBoot /Add-Driver /Driver:$bootPool /Recurse /ForceUnsigned
    if ($LASTEXITCODE -ne 0) { Log "FAIL boot 驱动注入"; throw "boot 驱动注入失败" }
    Dismount-WindowsImage -Path $mountBoot -Save | Out-Null
    Log "boot.wim 最小驱动集注入完成"
}
Log "== 驱动注入完成 =="

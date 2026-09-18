<#
.SYNOPSIS 03 - 离线注入 VC++ 2005~2022 官方逐项（扩展E）
.DESCRIPTION 挂载 install.wim 索引，逐项提取官方 redist 并注入 WinSxS。
   [SPIKE] VC++ 离线注入到 WinSxS 的方法必须在 Windows runner 实机验证：
         本版采用 "/extract -> msiexec /a 管理安装 -> dism /Add-Package" 路线，
         若某版本对离线映像不可行，回退到可信 AIO（abbodi1406）的离线 CAB。
         注入细节以 [INJECT] 占位，跑通前不并入生产。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\03-vcpp.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$mount = Join-Path $WorkDir 'mount'
$redist = Join-Path $WorkDir 'assets\redist'
if (-not (Test-Path $redist)) { Log "无 redist 目录，跳过 VC++ 注入"; return }

$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'   # [SPIKE] 路径随 W10UI 输出确认
if (Test-Path $mount) {
    # [坑] 上一阶段 -Save 卸载后 $mount 目录仍在，但已非挂载点；
    #      此时再 Dismount 会抛 COMException "The request is not supported."，
    #      且 -ErrorAction SilentlyContinue 挡不住（DISM cmdlet 抛的是终止错误）。
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
    catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
Log "已挂载 install.wim -> $mount"

# 顺序：2005 -> 2022；x86 先于 x64（用文件名排序近似）
$files = Get-ChildItem $redist -Filter 'vc_redist*.exe' | Sort-Object Name
foreach ($exe in $files) {
    $extracted = Join-Path $WorkDir "tmp\vcpp\$($exe.BaseName)"
    New-Item -ItemType Directory -Force -Path $extracted | Out-Null
    # 提取 MSI + CAB（部分版本语法为 '/extract:<dir>' 或 '/quiet /extract'）
    & $exe.FullName '/extract' | Out-Null
    # [INJECT] 实机验证后的注入命令（占位）：
    #   msiexec.exe /a "<extracted>\<pkg>.msi" TARGETDIR="<extracted>\admin"
    #   dism.exe /Image:$mount /Add-Package /PackagePath="<extracted>\<pkg>.cab"
    Log "VC++ $($exe.Name) 已提取至 $extracted；注入命令见 [INJECT]（需实机 spike 校准）"
}

Save-WindowsImage -Path $mount | Out-Null
Dismount-WindowsImage -Path $mount -Save | Out-Null
Log "== VC++ 提取完成（注入细节待实机 spike 校准，见脚本顶部 [SPIKE]）=="

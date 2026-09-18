<#
.SYNOPSIS 08 - 离线烤入 WIM（自动应答 + PostSetup 脚本）
.DESCRIPTION 挂载 install.wim，把首启所需的薄引导与用户脚本写入映像本体，
             与部署工具解耦（WinNTSetup / MDT / 标准安装均生效）：
               C:\Windows\Panther\unattend.xml        <- config\unattend-<branch>.xml（一次性，首启用完系统自删+兜底删）
               C:\Windows\Setup\Scripts\setupcomplete.cmd  <- config\setupcomplete.cmd（薄引导，跑完自删）
               C:\PostSetup\*                          <- postsetup\*（用户脚本，Run-All.ps1 调度，clean_after_run 决定去留）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\08-bake.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'   # [SPIKE] 路径随 W10UI 输出确认
if (Test-Path $mount) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
try {
    # unattend.xml -> Panther
    $unattendSrc = Join-Path $WorkDir "config\unattend-$BranchId.xml"
    $panther = Join-Path $mount 'Windows\Panther'
    New-Item -ItemType Directory -Force -Path $panther | Out-Null
    Copy-Item $unattendSrc (Join-Path $panther 'unattend.xml') -Force
    Log "烤入 unattend.xml -> $panther"

    # setupcomplete.cmd -> Setup\Scripts
    $scripts = Join-Path $mount 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    Copy-Item (Join-Path $WorkDir 'config\setupcomplete.cmd') (Join-Path $scripts 'setupcomplete.cmd') -Force
    Log "烤入 setupcomplete.cmd -> $scripts"

    # postsetup -> C:\PostSetup
    $postDst = Join-Path $mount 'PostSetup'
    New-Item -ItemType Directory -Force -Path $postDst | Out-Null
    Copy-Item (Join-Path $WorkDir 'postsetup\*') $postDst -Recurse -Force
    Log "烤入 PostSetup -> $postDst"
} finally {
    Dismount-WindowsImage -Path $mount -Save | Out-Null
}
Log "== 镜像烤入完成 =="

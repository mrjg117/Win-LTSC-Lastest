<#
.SYNOPSIS 00 - 预检 fail-fast
.DESCRIPTION 在跑 30-90 分钟长任务之前，校验上游与 delta 关键文件齐全、磁盘空间足够。
             任一缺失立即非零退出，避免空烧 runner。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,    # 上游快照 ./src 绝对路径
    [Parameter(Mandatory)] [string] $BranchId    # 19044 / 26100
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\00-precheck.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

Log "== 预检开始 (branch=$BranchId, workdir=$WorkDir) =="

# 上游关键文件（只读，必须存在且名字未变）
$required = @(
    (Join-Path $WorkDir 'W10UI.cmd'),
    (Join-Path $WorkDir 'W10UI.ini'),
    (Join-Path $WorkDir 'bin\7z.exe'),
    (Join-Path $WorkDir 'bin\aria2c.exe'),
    (Join-Path $WorkDir 'bin\oscdimg.exe')
)
foreach ($f in $required) {
    if (-not (Test-Path $f)) { Log "FAIL 缺少上游文件: $f"; throw "预检失败: $f" }
}
Log "上游关键文件齐全"

# delta 脚本齐全
$lib = Join-Path $WorkDir 'lib'
@('01.Build-Manifest.ps1','02.Fetch-Updates.ps1','03.Integrate-VCpp.ps1',
  '04.Integrate-Drivers.ps1','05.Integrate-Apps.ps1','06.Patch-Components.ps1',
  '07.Assert-UBR.ps1','08.Bake-Image.ps1','99.Force-W10UI-Ini.ps1') | ForEach-Object {
    if (-not (Test-Path (Join-Path $lib $_))) { Log "FAIL 缺少 delta 脚本: $_"; throw "预检失败: $_" }
}
Log "delta 脚本齐全"

# 磁盘空间（建议 >= 50GB 空闲于 WorkDir 所在盘）
$drive = (Get-Item $WorkDir).PSDrive.Name
$free = (Get-PSDrive -Name $drive).Free / 1GB
if ($free -lt 50) {
    Log "WARN 空闲空间 ${free:0.0} GB < 50GB（ISO解压+集成+重封装峰值 30-50GB），可能不够"
} else {
    Log "磁盘空闲 ${free:0.0} GB OK"
}

# baseline ISO 分块已重组？
$baselineIso = Join-Path $WorkDir "baseline-$BranchId.iso"
if (-not (Test-Path $baselineIso)) {
    Log "FAIL 未找到 baseline ISO: $baselineIso（检查 workflow 拉取/重组步骤）"
    throw "预检失败"
}
Log "baseline ISO 存在: $baselineIso"

Log "== 预检通过 =="

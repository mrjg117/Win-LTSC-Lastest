<#
.SYNOPSIS 09 - 最后一步：install.wim -> install.esd（LZMS，成品更小）
.DESCRIPTION [为什么转] install.wim 是 LZX 压缩；install.esd 用 LZMS（微软自家 ESD，
             官方零售版 ISO 就是 esd），同样的内容通常小 20~25%。
  [为什么必须放在最后] ESD 是只读格式，DISM 根本挂不上 —— 这正是
             W10UI.ini 的 wim2esd 红线保持 0 的原因：上游那一步（以及我们的 08 会话）
             后面还要挂载改镜像，一旦提前转成 esd，后面的 DISM 全线失败。
             所以上游继续产出 wim，转 ESD 只在 oscdimg 封装之前做一次。
  [怎么做] 照抄上游 W10UI.cmd 的做法（`!_wimlib! export sources\install.wim all
           sources\install.esd --compress=LZMS --solid`）：wimlib 多线程，比
           DISM /Export-Image /Compress:Recovery 快得多。wimlib 不在时才回退 DISM。
  [失败即中止] 转换失败不静默回退成 wim —— 产物形态不符合预期属"看起来成功"的坏结果。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}   # 见 00.Precheck.ps1：输出编码钉死 UTF-8
$log = Join-Path $WorkDir "logs\09-esd.log"
function Log($m){ $s = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $s; [System.IO.File]::AppendAllText($log, $s + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) }

$src = Join-Path $WorkDir 'ISO\sources\install.wim'
$dst = Join-Path $WorkDir 'ISO\sources\install.esd'

if (-not (Test-Path $src)) {
    if (Test-Path $dst) { Log "无 install.wim，但 install.esd 已在 -> 跳过转换"; return }
    Log "FAIL 找不到 $src（W10UI 段没产出？）"
    throw "缺少 install.wim"
}
if (Test-Path $dst) { Remove-Item $dst -Force }   # 清残留：export 到已存在的 esd 会追加索引
$before = (Get-Item $src).Length
Log ("源 install.wim {0:N2} GiB（{1} 字节）" -f ($before / 1GB), $before)

# wimlib 查找次序与上游 W10UI.cmd 一致：工作目录 > bin\ > bin\bin64\
$wimlib = $null
foreach ($c in @((Join-Path $WorkDir 'wimlib-imagex.exe'),
                 (Join-Path $WorkDir 'bin\wimlib-imagex.exe'),
                 (Join-Path $WorkDir 'bin\bin64\wimlib-imagex.exe'))) {
    if (Test-Path $c) { $wimlib = $c; break }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
if ($wimlib) {
    Log "wimlib: $wimlib"
    Log "wimlib-imagex export install.wim all install.esd --compress=LZMS --solid"
    & $wimlib export $src all $dst --compress=LZMS --solid
    $rc = $LASTEXITCODE
} else {
    Log "WARN 未找到 wimlib-imagex.exe -> 回退 DISM /Export-Image /Compress:Recovery（慢很多）"
    dism.exe /English /Export-Image /SourceImageFile:$src /SourceIndex:1 /DestinationImageFile:$dst /Compress:Recovery
    $rc = $LASTEXITCODE
}
Log "转换耗时 $([math]::Round($sw.Elapsed.TotalMinutes,1)) min（退出码 $rc）"

if ($rc -ne 0 -or -not (Test-Path $dst)) {
    if (Test-Path $dst) { Remove-Item $dst -Force }
    Log "FAIL ESD 转换失败，已清理半成品，install.wim 原样保留"
    throw "ESD 转换失败（退出码 $rc）"
}
$after = (Get-Item $dst).Length
Remove-Item $src -Force
Log ("ESD 完成: {0:N2} GiB -> {1:N2} GiB（省 {2:N1}%），install.wim 已删除，ISO\sources 只留 install.esd" -f `
      ($before / 1GB), ($after / 1GB), ((1 - $after / $before) * 100))

<#
.SYNOPSIS 08 - 单次挂载会话：把 03~07 合并进一次 mount / dismount
.DESCRIPTION [为什么合并] 03~07 全都发生在 W10UI 之后、都是对同一个 install.wim 的改动。
             原先各自 Mount-WindowsImage + Dismount -Save —— 每次卸载保存都要把整个镜像
             重新 LZX 压缩一遍（实测单次数分钟），连续 4 次纯属白花时间。
             合并后整条链只挂一次、只存一次。
  [分工] 本脚本只管两件事：挂载权 与 整链成败。
           挂载一次 -> 依次跑 03/04/05/06/07（都以 -MountDir 复用同一次挂载）
           -> 全绿   : Dismount -Save（仅一次）
           -> 任一步 throw : Dismount -Discard（不留半成品）
         各步逻辑仍各自留在 lib\0X.*.ps1，日志也各自独立（logs\0X-*.log），
         所以失败定位能力与合并前完全一致。
  [为什么 06 能塞进同一会话] 它只是挂载后 reg load SOFTWARE 读 build/UBR 做断言，只读不写；
           合并前它也要挂一次（-Discard 卸），现在连这次挂载都省了。
  [为什么 03 的 boot.wim 不合并] boot.wim 是另一个镜像、另一个挂载点，且只在
           assets\drivers\boot 非空时才动 —— 仍由 03 自己挂卸，不进本会话。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}   # 见 00.Precheck.ps1：输出编码钉死 UTF-8
$log = Join-Path $WorkDir "logs\08-session.log"
function Log($m){ $s = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $s; [System.IO.File]::AppendAllText($log, $s + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) }

$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'
if (-not (Test-Path $installWim)) { Log "FAIL 缺少 $installWim（W10UI 段没产出？）"; throw "缺少 install.wim" }

# 上一轮异常退出可能留下挂载点，先清掉，否则 Mount 必失败
if (Test-Path $mount) {
    # [坑] 目录存在 ≠ 仍是挂载点；对非挂载点 Dismount 会抛终止性 COMException
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
    catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $mount | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
Log "已挂载 install.wim -> $mount（$([int]$sw.Elapsed.TotalSeconds)s）；本次会话内跑完 03~07"

$steps = @(
    '03.Integrate-Drivers',
    '04.Integrate-Apps',
    '05.Patch-Components',
    '06.Assert-UBR',
    '07.Bake-Image'
)
$done = @()
try {
    foreach ($s in $steps) {
        $p = Join-Path $WorkDir "lib\$s.ps1"
        if (-not (Test-Path $p)) { throw "缺少步骤脚本: $p" }
        Log "---- [$s] ----"
        & $p -WorkDir $WorkDir -BranchId $BranchId -MountDir $mount
        # 不查 $?：各步内部对"可容忍的失败"（如 05 里已被 LCU 取代、必然装不回去的包）
        # 只记 WARN 不 throw，而 dism 返回非 0 会让 $? 变 False —— 拿 $? 兜底会把这类
        # 有意容忍的情况误判成致命失败，进而 Discard 掉整条链的改动。只认 throw。
        $done += $s
        Log "---- [$s] 完成（累计 $([int]$sw.Elapsed.TotalSeconds)s）----"
    }
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    Log "== 会话完成：$($done.Count)/$($steps.Count) 步全部成功，已卸载保存（总 $([math]::Round($sw.Elapsed.TotalMinutes,1)) min）=="
} catch {
    $where = if ($done.Count -gt 0) { "$($done[-1]) 之后" } else { '第 1 步' }
    Log "FAIL 会话中止于 $where —— $($_.Exception.Message)"
    try {
        Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null
        Log "已 Discard 卸载：镜像保持改动前的状态（本次会话的改动全部丢弃）"
    } catch { Log "WARN Discard 卸载失败: $($_.Exception.Message)" }
    throw
}

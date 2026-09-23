<#
.SYNOPSIS 06 - 断言 + 回写实测版本
.DESCRIPTION 挂载 install.wim，读离线 SOFTWARE hive 的 CurrentBuildNumber / UBR：
               1) build 必须落在 config.json 该分支的 family 内（否则疑似选错基线或集成异常）
               2) 实测 UBR 回写 manifest.json 的 targetUBR —— 产物标签一律用实测值
             断言失败即非零退出，构建中止（不留半成品）。
   [背景] 同一平台的多个年度版本共享累积更新与版本启用包（enablement package），
          上游 meta4 里含启用包，集成后 build 会从基线数跳到该平台当前最新分支
          （实测：26100.1742 --补丁--> 26300.9457，即 LTSC2024 基线 -> 26H2）。
          这是上游行为而非错误，所以 family 里显式列出允许的跳跃区间。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId,
    # 由 08.Image-Session 传入：非空 = 复用外部那一次挂载（本脚本不挂也不卸）
    [string] $MountDir
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}   # 见 00.Precheck.ps1：输出编码钉死 UTF-8
$log = Join-Path $WorkDir "logs\06-assert.log"
function Log($m){ $s = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $s; [System.IO.File]::AppendAllText($log, $s + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) }

$ownsMount = -not $MountDir
$mount = if ($MountDir) { $MountDir } else { Join-Path $WorkDir 'mount' }
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'
$manifest = Get-Content (Join-Path $WorkDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$targetBuild = [int]$manifest.build
$family = @(@($manifest.family) | ForEach-Object { [int]$_ })
if ($family.Count -eq 0) { $family = @($targetBuild) }

if ($ownsMount) {
    if (Test-Path $mount) {
        # [坑] 目录存在 ≠ 仍是挂载点；对非挂载点 Dismount 会抛终止性 COMException
        try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
        catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
    }
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
} else {
    Log "复用 08 会话的挂载: $mount"
}
try {
    $hive = Join-Path $mount 'Windows\System32\config\SOFTWARE'
    & reg.exe load 'HKLM\OFFLINE' $hive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load OFFLINE 失败" }
    # [关键] 读离线 hive 走 .NET，不用 PS provider（Get-ItemProperty 会留句柄、阻止下方 unload）
    $off = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('OFFLINE', $false)
    $cv  = $off.OpenSubKey('Microsoft\Windows NT\CurrentVersion')
    $curBuild = [int]($cv.GetValue('CurrentBuildNumber'))
    $curUBR   = [int]($cv.GetValue('UBR'))
    $cv.Close(); $off.Close()
    Log "实测 build=$curBuild UBR=$curUBR（基线 build=$targetBuild，家族 [$($family -join ',')]）"

    if ($family -notcontains $curBuild) {
        throw "断言失败: build $curBuild 不在 $BranchId 的家族 [$($family -join ',')] 内（疑似选错基线 ISO，或 config.yml 的 family 需更新）"
    }
    if ($curBuild -ne $targetBuild) {
        Log "WARN build 由基线 $targetBuild 变为 $curBuild（家族内）：上游 meta4 含版本启用包，已随补丁升级到该平台当前最新分支。"
    }

    # 回写实测值，供工作流拼产物标签（不写死、不猜）
    $manifest | Add-Member -MemberType NoteProperty -Name actualBuild -Value $curBuild -Force
    $manifest | Add-Member -MemberType NoteProperty -Name actualUBR   -Value $curUBR   -Force
    $manifest.targetUBR = "$curUBR"
    # 同上（见 01）：走 .NET 显式编码，避免 PS 5.1/7 的 BOM 行为差异
    [IO.File]::WriteAllText((Join-Path $WorkDir 'manifest.json'),
                            ($manifest | ConvertTo-Json -Depth 5),
                            (New-Object Text.UTF8Encoding($false)))
    Log "已回写实测版本 -> manifest.json: ${curBuild}.${curUBR}"

    Log "== 断言通过: build=$curBuild UBR=$curUBR =="
} finally {
    # 先 GC 兜底释放 .NET 句柄，再 unload，避免 Access denied（与 07 同源）
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
    & reg.exe unload 'HKLM\OFFLINE' 2>$null | Out-Null
    # 只卸自己挂的那次；08 会话里这步是只读断言，绝不能 Discard 掉前面 04/05 的改动
    if ($ownsMount) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
}

<#
.SYNOPSIS 05 - 精简组件（按 config.json 的 remove 清单）
.DESCRIPTION 挂载 install.wim，按下述合并清单卸载：
               全局 remove（对所有分支生效） + branches.<分支>.remove（本分支额外）
             名字形态自动分流；不匹配任何形态即失败（不静默跳过）：
               含 ~~~~           -> /Remove-Capability
               以 -Package 结尾   -> /Remove-Package
               其余              -> /Disable-Feature
   [注意] 名字需用真机 Get-WindowsCapability / Get-WindowsPackage 校准；
          不存在、或已被累积更新取代的项记 SKIP 而不是 WARN ——
          微软官方 Removable Packages 一旦被后续 LCU 取代就再也无法移除（CBS 报错），
          必然失败的项不该把日志刷满。
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
$log = Join-Path $WorkDir "logs\05-lean.log"
function Log($m){ $s = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $s; [System.IO.File]::AppendAllText($log, $s + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) }

$cfg   = Get-Content (Join-Path $WorkDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$g     = @($cfg.remove)
$b     = @($cfg.branches.$BranchId.remove)
$names = @(@($g + $b) | Where-Object { $_ } | Select-Object -Unique)
if ($names.Count -eq 0) { Log "remove 清单为空 -> 跳过组件精简"; return }
Log "清单 $($names.Count) 项（全局 $($g.Count) + 分支 $($b.Count)，合并去重后）"

# 名字形态分流 —— 与 tools/config-to-json.py 的 check_remove_name 必须完全一致
function Form([string] $n) {
    if ($n -like '*~~~~*')    { return 'capability' }
    if ($n -like '*-Package') { return 'package' }
    if ($n -match '\s')       { throw "无法分流（名字含空格）: $n" }
    return 'feature'
}

$ownsMount = -not $MountDir
$mount = if ($MountDir) { $MountDir } else { Join-Path $WorkDir 'mount' }
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'
if ($ownsMount) {
    if (Test-Path $mount) {
        # [坑] 目录存在 ≠ 仍是挂载点；对非挂载点 Dismount 会抛终止性 COMException
        try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
        catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
    }
    New-Item -ItemType Directory -Force -Path $mount | Out-Null
    Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
    Log "已挂载 install.wim -> $mount"
} else {
    Log "复用 08 会话的挂载: $mount"
}

# 只枚举一次（每次 -Path 枚举都要走一遍 wim，开销不小）
$caps = @(); $pkgs = @()
try { $caps = @(Get-WindowsCapability -Path $mount -ErrorAction Stop) } catch { Log "WARN 枚举 capability 失败: $($_.Exception.Message)" }
try { $pkgs = @(Get-WindowsPackage -Path $mount -ErrorAction Stop | Select-Object -ExpandProperty PackageName) } catch { Log "WARN 枚举已装包失败: $($_.Exception.Message)" }

$rcCap = 0; $rcPkg = 0; $rcFeat = 0; $skipped = 0
foreach ($n in $names) {
    switch (Form $n) {
        'capability' {
            # [关键] 离线映像的 DISM 选项是 /Remove-Capability，不是 /Remove-WindowsCapability
            #        （后者报 Error 87: the remove-windowscapability option is unknown）
            $hit = $caps | Where-Object { $_.Name -ieq $n -and $_.State -eq 'Installed' }
            if (-not $hit) { Log "SKIP capability 未安装/不存在: $n"; $skipped++; continue }
            dism.exe /Image:$mount /Remove-Capability /CapabilityName:$n
            if ($LASTEXITCODE -ne 0) { Log "WARN Remove-Capability 失败: $n" } else { $rcCap++ }
        }
        'package' {
            if ($pkgs -notcontains $n) { Log "SKIP 包不存在（或已被更新取代，不可移除）: $n"; $skipped++; continue }
            dism.exe /Image:$mount /Remove-Package /PackageName:$n
            if ($LASTEXITCODE -ne 0) { Log "WARN Remove-Package 失败: $n" } else { $rcPkg++ }
        }
        'feature' {
            # [坑·实测] 离线映像的选项名是 /Disable-Feature，不是 /Disable-WindowsOptionalFeature
            #   （后者报 Error 87: the disable-windowsoptionalfeature option is unknown ——
            #    19044 实测：MicrosoftWindowsPowerShellV2 / V2Root 两条都栽在这里，被静默 WARN 掉，
            #    于是"写了要卸的项其实没卸"）。与上面 /Remove-Capability 属同一类坑。
            dism.exe /Image:$mount /Disable-Feature /FeatureName:$n /Remove
            if ($LASTEXITCODE -ne 0) { Log "WARN Disable-Feature 失败: $n" } else { $rcFeat++ }
        }
    }
}
if ($ownsMount) {
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    Log "== 组件精简完成: capability $rcCap / package $rcPkg / feature $rcFeat，跳过 $skipped（本步自行卸载保存）=="
} else {
    Log "== 组件精简完成: capability $rcCap / package $rcPkg / feature $rcFeat，跳过 $skipped（挂载由 08 会话统一收尾）=="
}

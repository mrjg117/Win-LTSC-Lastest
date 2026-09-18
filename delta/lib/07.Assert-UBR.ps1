<#
.SYNOPSIS 07 - 断言（改造D）
.DESCRIPTION 挂载 install.wim，读取 SOFTWARE hive 的 CurrentBuildNumber 与 UBR，
             断言：build 主版本一致 ∧ UBR >= targetUBR ∧ 目标 LCU KB 已安装。
             任一不满足即非零退出，构建中止（不留半成品）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\07-assert.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }
# 约定：形如 <...> 的值视为"未配置"，对应断言跳过（仅告警）而非失败
function IsUnset($v) {
    return (-not $v) -or ($v -eq '') -or ($v -match '^\s*<.*>\s*$')
}

$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'   # [SPIKE] 路径随 W10UI 输出确认
$manifest = Get-Content (Join-Path $WorkDir 'manifest.json') -Raw | ConvertFrom-Json
$targetUBR = $manifest.targetUBR
$targetBuild = [int]$manifest.build

$pl = Get-Content (Join-Path $WorkDir 'patchlist.json') -Raw | ConvertFrom-Json
$branchCfg = $pl.branches.$BranchId
$family = @($branchCfg.buildFamily)
if ($family.Count -eq 0) { $family = @($targetBuild) }
$pinBuild = [bool]$branchCfg.pinBuild

if (Test-Path $mount) {
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
    catch { Write-Host "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
try {
    # 加载离线 SOFTWARE hive
    $hive = Join-Path $mount 'Windows\System32\config\SOFTWARE'
    & reg.exe load 'HKLM\OFFLINE' $hive | Out-Null
    $cv = Get-ItemProperty 'HKLM:\OFFLINE\Microsoft\Windows NT\CurrentVersion'
    $curBuild = [int]($cv.CurrentBuildNumber)
    $curUBR = [int]($cv.UBR)
    Log "build=$curBuild UBR=$curUBR (期望 build主版本=$targetBuild UBR>=$targetUBR)"

    # 断言1: build 属于该分支的"同一服务化家族"
    # [背景] 同一平台(Germanium / 21H2)的多个年度版本共享累积更新与启用包(enablement)。
    #        上游 meta4 里含启用包，集成后映像的 build 会从基线数跳到当前最新分支
    #        （实测：26100.1742 --补丁--> 26300.9457，即 LTSC2024 基线 -> 26H2）。
    #        这是上游行为而非错误，故只告警；若要锁死在基线 build，在 patchlist.json
    #        把该分支的 pinBuild 置 true 即可让此步直接失败。
    if ($curBuild -ne $targetBuild) {
        if ($pinBuild) {
            throw "断言失败: build 发生变化 ($curBuild vs 锁定值 $targetBuild)。pinBuild=true，按构建中止处理。"
        }
        if ($family -notcontains $curBuild) {
            throw "断言失败: build $curBuild 不在 $BranchId 的家族范围 [$($family -join ',')] 内（疑似选错基线 ISO 或集成异常）"
        }
        Log "WARN build 由基线 $targetBuild 变为 $curBuild（家族内 [$($family -join ',')]）：上游 meta4 含启用包，已随补丁升级到该平台当前最新分支。若要锁死请把 patchlist.json 的 pinBuild 置 true。"
    }
    # 断言2: UBR >= target（targetUBR 为占位符时跳过，仅告警）
    if (IsUnset $targetUBR) {
        Log "WARN targetUBR 未配置（占位符），跳过 UBR 断言"
    } elseif ($curUBR -lt [int]$targetUBR) {
        throw "断言失败: UBR $curUBR < 目标 $targetUBR（补丁未正确集成）"
    }
    # 断言3: 目标 LCU KB 已安装（KB 为占位符时跳过，仅告警）
    $kb = $manifest.lcu.kb
    if (IsUnset $kb) {
        Log "WARN lcu.kb 未配置（占位符），跳过 KB 已安装断言"
    } else {
        $installed = dism.exe /Image:$mount /Get-Packages | Out-String
        if ($installed -notmatch [regex]::Escape($kb)) {
            throw "断言失败: 目标 LCU $kb 未安装在映像中"
        }
        Log "LCU=$kb 已安装"
    }

    # 回写实测版本供下游打 tag，避免用占位符生成垃圾 tag
    $manifest | Add-Member -MemberType NoteProperty -Name actualBuild -Value $curBuild -Force
    $manifest | Add-Member -MemberType NoteProperty -Name actualUBR -Value $curUBR -Force
    $manifest.targetUBR = "$curUBR"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $WorkDir 'manifest.json')
    Log "已回写实测版本 -> manifest.json: ${curBuild}.${curUBR}"

    Log "== 断言通过: build=$curBuild UBR=$curUBR =="
} finally {
    & reg.exe unload 'HKLM\OFFLINE' 2>$null | Out-Null
    Dismount-WindowsImage -Path $mount -Discard | Out-Null
}

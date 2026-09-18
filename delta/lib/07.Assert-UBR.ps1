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
$targetBuild = $manifest.build

if (Test-Path $mount) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue }
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

    # 断言1: build 主版本一致
    if ([Math]::Floor($curBuild/100) -ne [Math]::Floor($targetBuild/100)) {
        throw "断言失败: build 主版本不一致 ($curBuild vs 期望 $targetBuild)"
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

    # 回写实测 UBR 供下游打 tag，避免用占位符生成垃圾 tag
    $manifest.targetUBR = "$curBuild.$curUBR"
    $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $WorkDir 'manifest.json')
    Log "已回写实测 UBR -> manifest.json: $($manifest.targetUBR)"

    Log "== 断言通过: build=$curBuild UBR=$curUBR =="
} finally {
    & reg.exe unload 'HKLM\OFFLINE' 2>$null | Out-Null
    Dismount-WindowsImage -Path $mount -Discard | Out-Null
}

<#
.SYNOPSIS 04 - 离线预置应用（按 config.json 的 apps 清单）
.DESCRIPTION 载荷在构建期由 tools/fetch-payloads.py 抓好，落在 assets\apps\<键>\：
               主包（.msixbundle/.appxbundle/.msix/.appx）、依赖框架（.msix）、可选 license.xml
             清单与相对路径写在 assets\apps\apps-manifest.json（抓取脚本产出，本脚本只读它，
             所以「装什么」的唯一真相源是 config.yml，路径由抓取脚本落成契约）。
             挂载 install.wim 后逐个 /Add-ProvisionedAppxPackage：
               license 存在   -> 带 /LicensePath
               license 不存在 -> /SkipLicense
             [约束] 非 Store 来源的包用 /SkipLicense 预置后，用户首次登录注册需要
                    SOFTWARE 策略 AllowAllTrustedApps=1 —— 由 optimize 的
                    allow_all_trusted_apps 在 07.Bake-Image 里离线写入（别删那一条）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\04-apps.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$manifestPath = Join-Path $WorkDir 'assets\apps\apps-manifest.json'
if (-not (Test-Path $manifestPath)) {
    Log "无 assets\apps\apps-manifest.json（构建期未抓取载荷）-> 跳过应用预置"
    return
}
$man  = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$recs = @($man.apps)
if ($recs.Count -eq 0) { Log "分支 $BranchId 的 apps 清单为空 -> 跳过"; return }

# manifest 里的路径以 WorkDir 为根；统一转绝对路径
function Abs([string] $rel) { Join-Path $WorkDir ($rel -replace '/', '\') }

$mount = Join-Path $WorkDir 'mount'
$installWim = Join-Path $WorkDir 'ISO\sources\install.wim'
if (Test-Path $mount) {
    # [坑] 目录存在 ≠ 仍是挂载点；对非挂载点 Dismount 会抛终止性 COMException
    try { Dismount-WindowsImage -Path $mount -Discard -ErrorAction Stop | Out-Null }
    catch { Log "WARN 残留挂载点清理跳过（非挂载点）: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $mount | Out-Null
Mount-WindowsImage -ImagePath $installWim -Index 1 -Path $mount | Out-Null
Log "已挂载 install.wim -> $mount（$($recs.Count) 个应用）"

foreach ($rec in $recs) {
    $main = Abs (@($rec.main)[0])
    if (-not (Test-Path $main)) { throw "apps 载荷缺失: $main（抓取步骤没跑或失败）" }
    $dargs = @('/Image:' + $mount, '/Add-ProvisionedAppxPackage', '/PackagePath:' + $main)
    $lic = if ($rec.license) { Abs $rec.license } else { $null }
    if ($lic -and (Test-Path $lic)) {
        $dargs += '/LicensePath:' + $lic
        Log "$($rec.key): 带 license"
    } else {
        $dargs += '/SkipLicense'
        Log "$($rec.key): 无 license -> /SkipLicense"
    }
    $deps = @(@($rec.deps) | ForEach-Object { Abs $_ } | Where-Object { Test-Path $_ })
    if ($deps.Count -gt 0) {
        $dargs += '/DependencyPackagePath:' + ($deps -join ',')
        Log "$($rec.key): 依赖 $($deps.Count) 个"
    }
    Log "provision $($rec.key) <- $(Split-Path $main -Leaf)"
    dism.exe /English @dargs
    if ($LASTEXITCODE -ne 0) { Log "FAIL provision $($rec.key)（DISM 退出码 $LASTEXITCODE）"; throw "应用预置失败: $($rec.key)" }
    Log "OK $($rec.key)"
}
Dismount-WindowsImage -Path $mount -Save | Out-Null
Log "== 应用预置完成 =="

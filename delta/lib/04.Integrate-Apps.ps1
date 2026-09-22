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
    [Parameter(Mandatory)] [string] $BranchId,
    # 由 08.Image-Session 传入：非空 = 复用外部那一次挂载（本脚本不挂也不卸）
    [string] $MountDir
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}   # 见 00.Precheck.ps1：输出编码钉死 UTF-8
$log = Join-Path $WorkDir "logs\04-apps.log"
function Log($m){ $s = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $s; [System.IO.File]::AppendAllText($log, $s + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) }

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
    Log "已挂载 install.wim -> $mount（$($recs.Count) 个应用）"
} else {
    Log "复用 08 会话的挂载: $mount（$($recs.Count) 个应用）"
}

foreach ($rec in $recs) {
    $main = Abs (@($rec.main)[0])
    if (-not (Test-Path $main)) { throw "apps 载荷缺失: $main（抓取步骤没跑或失败）" }
    # [坑·致命] PowerShell 里逗号(,)优先级高于加号(+)，`@('/Image:' + $mount, 'B', '/C:' + $main)`
    #   会被解析成 `@('/Image:' + ($mount,'B','/C:') + $main)` —— 三元组先成数组、再被字符串 +
    #   拼接成 **一个** 元素（数组转字符串用空格连接）：
    #     count=1 -> "/Image:D:\...\mount /Add-ProvisionedAppxPackage /PackagePath:D:\...xxx.msixbundle"
    #   DISM 收到这个畸形单参 -> `Error: 123 Unable to access the image`（19044 实测即死在此）。
    #   故每个 `+` 表达式必须各自加括号。
    $dargs = @(('/Image:' + $mount), '/Add-ProvisionedAppxPackage', ('/PackagePath:' + $main))
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
        # [坑·致命] /DependencyPackagePath 必须**每个依赖一个开关**。微软官方语法与示例都是重复开关：
        #     Dism /Online /Add-ProvisionedAppxPackage /PackagePath:Main.appx
        #       /DependencyPackagePath:...\Framework-x86.appx /DependencyPackagePath:...\Framework-x64.appx
        #   写成 `'/DependencyPackagePath:' + ($deps -join ',')` 只会得到**一个**参数，形如
        #     /DependencyPackagePath:D:\...\a.appx,D:\...\b.appx
        #   DISM 不认逗号分隔，把整串当成**单个路径**，其中第二个驱动器冒号让「文件名」非法 ->
        #     Error: 123  The filename, directory name, or volume label syntax is incorrect.
        #   （CI #24 实测即死在此：7 个依赖 -> 123；DISM 已打印 Image Version 说明镜像访问正常，
        #     失败发生在参数解析，不是镜像/挂载问题。）
        foreach ($d in $deps) { $dargs += ('/DependencyPackagePath:' + $d) }
        Log "$($rec.key): 依赖 $($deps.Count) 个（逐个 /DependencyPackagePath 开关）"
    }
    Log "provision $($rec.key) <- $(Split-Path $main -Leaf)"
    # 打印实际命令行：失败时它随末 25 行进 annotation，**无需登录即可复核参数**（这次 123 就是靠这条路定位的）
    Log ("DISM 参数: " + ($dargs -join ' '))
    dism.exe /English @dargs
    if ($LASTEXITCODE -ne 0) {
        Log "FAIL provision $($rec.key)（DISM 退出码 $LASTEXITCODE）"
        # DISM 在屏幕上只回一句 `Error: 123`，真正的原因在它自己的日志里。失败时把尾部带出来 ——
        # 它会随 logs\Patch.log 的末 25 行进 GitHub annotation，**无需登录即可看到根因**。
        $dismLog = Join-Path $env:windir 'Logs\DISM\dism.log'
        if (Test-Path $dismLog) {
            Get-Content $dismLog -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Log ("  DISM| " + $_) }
        }
        throw "应用预置失败: $($rec.key)"
    }
    Log "OK $($rec.key)"
}
if ($ownsMount) {
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    Log "== 应用预置完成（本步自行卸载保存）=="
} else {
    Log "== 应用预置完成（挂载由 08 会话统一收尾）=="
}

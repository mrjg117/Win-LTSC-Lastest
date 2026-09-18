<#
.SYNOPSIS 02b - 用上游 meta4(Metalink) 下载补丁到 patch\（W10UI 的 Repo）
.DESCRIPTION 对齐上游 Start.cmd 的 [4/4] 下载环节：
             aria2c -M Scripts\script_<build>_<arch>.meta4 -d patch
             W10UI.cmd 本身不下载更新，只集成 Repo(=%cd%\patch) 下已有的补丁；
             若 patch\ 为空则 cmd_repo=0，等于没打补丁。故本步是必需环节。
             build 映射规则同 Start.cmd（meta4 文件名用的是映射后的 build）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\02b-fetch-meta4.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

# ---- 选 aria2c（与 Start.cmd 一致：amd64 主机优先 bin\bin64） ----
$aria2 = Join-Path $WorkDir 'bin\bin64\aria2c.exe'
if (-not (Test-Path $aria2)) { $aria2 = Join-Path $WorkDir 'bin\aria2c.exe' }
if (-not (Test-Path $aria2)) { throw "未找到 aria2c: $aria2" }

$manifest = Get-Content (Join-Path $WorkDir 'manifest.json') -Raw | ConvertFrom-Json
$rawBuild = [int]$manifest.build
$arch     = ($manifest.arch).ToString().ToLower()   # x64 / arm64 / x86
# 兜底：01 若因故未识别出 arch，meta4 文件名会变成 script_<build>_.meta4 而必然找不到
if ($arch -notmatch '^(x64|x86|arm64)$') { $arch = 'x64'; Log "WARN manifest.arch 异常，兜底取 x64" }

# ---- build 映射（严格照抄 Start.cmd，meta4 文件名用映射后的值） ----
$build = $rawBuild
if ($rawBuild -ge 19042 -and $rawBuild -le 19045) { $build = 19041 }
elseif ($rawBuild -eq 20349) { $build = 20348 }
elseif ($rawBuild -eq 22631) { $build = 22621 }
elseif ($rawBuild -ge 26200 -and $rawBuild -le 26300) { $build = 26100 }
Log "build 映射: $rawBuild -> $build (arch=$arch)"

$patchDir = Join-Path $WorkDir 'patch'
New-Item -ItemType Directory -Force -Path $patchDir | Out-Null

function HasUpdates($dir) {
    return (Test-Path (Join-Path $dir '*Windows1*-KB*.*')) -or (Test-Path (Join-Path $dir 'SSU-*-*.*'))
}

function Invoke-Meta4($metaRel, $lang) {
    $meta = Join-Path $WorkDir $metaRel
    if (-not (Test-Path $meta)) { Log "WARN 缺少 meta4: $metaRel（跳过）"; return $true }
    Log "下载 meta4: $metaRel $(if($lang){"lang=$lang"} else {''})"
    for ($i = 1; $i -le 5; $i++) {
        $a = @('--no-conf','--check-certificate=false','-x16','-s16','-j5','-c','-R',
               '-d', $patchDir, '-M', $meta,
               "--log=$(Join-Path $patchDir 'aria2.log')", '--log-level=notice')
        if ($lang) { $a += "--metalink-language=$lang" }
        & $aria2 @a
        if ($LASTEXITCODE -eq 0) { Log "OK aria2 完成 ($metaRel) 第 $i 次尝试"; return $true }
        Log "WARN aria2 退出码 $LASTEXITCODE（第 $i/5 次），清理后重试"
        # 与 Start.cmd 一致：重试前清掉半成品，避免 -c 跳过校验失败的文件
        Get-ChildItem $patchDir -Include *.msu,*.cab,*.msu.aria2,*.cab.aria2 -File -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    }
    return $false
}

# ---- 1) 主补丁（LCU/SSU） ----
$metaFile = "Scripts\script_$($build)_$($arch).meta4"
# 主补丁 meta4 是必需项：缺失就立刻报清楚，不要静默跳过再在最后抛含糊的"没补丁"
if (-not (Test-Path (Join-Path $WorkDir $metaFile))) {
    throw "缺少主补丁 meta4: $metaFile（build 映射 $rawBuild -> $build, arch=$arch）"
}
if (-not (Invoke-Meta4 $metaFile $null)) {
    throw "meta4 下载失败（重试 5 次仍失败）: $metaFile"
}

# ---- 2) .NET Framework 补丁（Start.cmd：build 19041~22000 才取） ----
if ($build -ge 19041 -and $build -le 22000) {
    $nf481 = Join-Path $WorkDir "Scripts\netfx4.8.1\script_netfx4.8.1_$($build)_$($arch).meta4"
    $nf48  = Join-Path $WorkDir "Scripts\netfx4.8\script_netfx4.8_$($build)_$($arch).meta4"
    if (Test-Path $nf481) {
        # neutral 必取；语言包需 manifest.lang，本版未提供则只取 neutral
        [void](Invoke-Meta4 "Scripts\netfx4.8.1\script_netfx4.8.1_$($build)_$($arch).meta4" 'neutral')
    } elseif (Test-Path $nf48) {
        [void](Invoke-Meta4 "Scripts\netfx4.8\script_netfx4.8_$($build)_$($arch).meta4" 'neutral')
    } else {
        Log "WARN 未找到 netfx meta4，跳过 .NET 补丁下载"
    }
}

# ---- 3) 校验 patch\ 确实有补丁，否则 W10UI 会 cmd_repo=0（等于白跑） ----
if (-not (HasUpdates $patchDir)) {
    throw "patch\ 下未找到任何补丁（*Windows1*-KB* / SSU-*），W10UI 将无补丁可集成"
}
$cnt = (Get-ChildItem $patchDir -File -ErrorAction SilentlyContinue | Measure-Object).Count
Log "patch\ 共 $cnt 个文件，已具备补丁"
Log "== meta4 下载完成 =="

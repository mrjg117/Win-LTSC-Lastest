<#
.SYNOPSIS 02 - 下载补丁（改造B），aria2 多线程 + SHA1 校验
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\02-fetch.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$aria2 = Join-Path $WorkDir 'bin\aria2c.exe'
$manifest = Get-Content (Join-Path $WorkDir 'manifest.json') -Raw | ConvertFrom-Json
# 下载目录必须是 patch\：W10UI.ini 的 Repo=%cd%\patch，只有这里的文件才会被集成
$out = Join-Path $WorkDir 'patch'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# 约定：patchlist.json / manifest.json 中形如 <...> 的值视为"未配置"
function IsUnset($v) {
    return (-not $v) -or ($v -eq '') -or ($v -match '^\s*<.*>\s*$')
}

$downloaded = 0
foreach ($item in @($manifest.lcu, $manifest.ssu)) {
    if (-not $item) { continue }
    # 未配置直链/SHA1 时不硬下载：上游 W10UI.cmd 本身会按其 Scripts/*.meta4
    # (Metalink, 含 URL+校验值) 拉取并集成当月最新更新，此处不重复实现。
    if ((IsUnset $item.url) -or (IsUnset $item.sha1)) {
        Log "WARN $($item.kb) 未配置直链/SHA1（占位符），跳过下载；更新集成交由上游 W10UI.cmd"
        continue
    }
    $dst = Join-Path $out "$($item.kb).msu"
    $args = @('-x16','-s16','-c','--retry-wait=5','--max-tries=3',
               "--checksum=sha-1=$($item.sha1)", '-d', $out, '-o', "$($item.kb).msu", $item.url)
    Log "下载 $($item.kb) -> $dst"
    & $aria2 @args
    if ($LASTEXITCODE -ne 0) { Log "FAIL 下载 $($item.kb)"; throw "下载失败" }
    $actual = (Get-FileHash $dst -Algorithm SHA1).Hash
    if ($actual -ne $item.sha1) {
        Log "FAIL SHA1 不符 期望=$($item.sha1) 实际=$actual"
        throw "校验失败"
    }
    Log "OK $($item.kb) SHA1 校验通过"
    $downloaded++
}
if ($downloaded -eq 0) {
    Log "WARN 本次未从 patchlist 下载任何补丁，完全依赖上游 W10UI.cmd 集成最新更新"
}
Log "== 下载完成 =="

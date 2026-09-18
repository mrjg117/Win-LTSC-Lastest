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
$out = Join-Path $WorkDir 'updates'
New-Item -ItemType Directory -Force -Path $out | Out-Null

foreach ($item in @($manifest.lcu, $manifest.ssu)) {
    if (-not $item.url -or $item.url -eq '') {
        # [SPIKE] 若 url 留空，需 Build-Manifest 从 UUPdump API 解析；本版要求 patchlist 填直链
        Log "WARN $($item.kb) 无 url，跳过下载（请在 patchlist.json 填直链或由 UUPdump 解析）"
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
}
Log "== 下载完成 =="

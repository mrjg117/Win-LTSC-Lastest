<#
.SYNOPSIS 01 - 生成构建清单 manifest.json（改造A）
.DESCRIPTION 读 baseline ISO 的 build/arch，结合 patchlist.json 的目标 UBR/LCU/SSU，
             产出 manifest.json 供后续脚本与断言使用。
             UBR/LCU 权威来源可扩展为 UUPdump API（[SPIKE] 抓取稳定性需实机验证），
             本版以 patchlist.json 配置驱动为主，确保可控。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId,
    [string] $PatchList = "patchlist.json",
    [string] $UpstreamCommit = $env:UPSTREAM_COMMIT
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\01-manifest.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

# 1) 读 baseline ISO 的 build/arch（7z 解 sources\install.wim 读 DISM 信息）
$baselineIso = Join-Path $WorkDir "baseline-$BranchId.iso"
$tmpExtract = Join-Path $WorkDir "iso-extract"
$installWim = Join-Path $tmpExtract 'sources\install.wim'
if (-not (Test-Path $installWim)) {
    New-Item -ItemType Directory -Force -Path $tmpExtract | Out-Null
    & (Join-Path $WorkDir 'bin\7z.exe') x $baselineIso "-o$tmpExtract" 'sources/install.wim' | Out-Null
}
$wimInfo = dism.exe /English /Get-WimInfo /WimFile:$installWim /Index:1 | Out-String
$build = [regex]::Match($wimInfo, 'Version\s*:\s*(\d+\.\d+\.\d+)').Groups[1].Value
$arch  = [regex]::Match($wimInfo, 'Architecture\s*:\s*(\w+)').Groups[1].Value
Log "baseline build=$build arch=$arch"

# 2) 读 patchlist.json 目标
$pl = Get-Content (Join-Path $WorkDir $PatchList) -Raw | ConvertFrom-Json
$br = $pl.branches.$BranchId
$manifest = [ordered]@{
    branch       = $BranchId
    build        = $br.build
    arch         = $arch
    sku          = $br.sku
    targetUBR    = $br.targetUBR
    lcu          = $br.lcu
    ssu          = $br.ssu
    engineCommit = $UpstreamCommit
    generatedAt  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $WorkDir 'manifest.json')
Log "manifest.json 已生成: targetUBR=$($br.targetUBR)"

<#
.SYNOPSIS 01 - 生成构建清单 manifest.json
.DESCRIPTION 读 baseline ISO 的 build/arch（DISM /Get-WimInfo），与 config.json 的分支定义合并，
             产出 manifest.json 供后续脚本与断言使用。
             UBR 不在这里猜：由 06.Assert-UBR 读离线 hive 实测后回写 manifest.targetUBR，
             产物标签用的是实测值，不会出现占位符拼出来的垃圾 tag。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId,
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
# Version 形如 10.0.26100 —— build 必须取最后一段，整串 [int] 会抛错
$ver  = [regex]::Match($wimInfo, 'Version\s*:\s*(\d+\.\d+\.\d+)').Groups[1].Value
$arch = [regex]::Match($wimInfo, 'Architecture\s*:\s*(\w+)').Groups[1].Value
if (-not $ver) { throw "无法从 WIM 识别 Version（DISM 输出异常）" }
$build = [int]($ver.Split('.')[-1])
Log "baseline Version=$ver -> build=$build arch=$arch"

# 2) 合 config.json 的分支定义（唯一控制面板）
$cfg = Get-Content (Join-Path $WorkDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$br = $cfg.branches.$BranchId
if (-not $br) { throw "config.json 里没有分支 $BranchId" }

$manifest = [ordered]@{
    branch       = $BranchId
    label        = $br.label
    edition      = $br.edition          # Set-Edition 的目标 SKU（07.Bake-Image 用）
    family       = @($br.family)        # 允许的 build 家族（06.Assert-UBR 用）
    build        = $build
    arch         = $arch
    targetUBR    = $null                # 由 06 实测后回写，勿在此处猜
    engineCommit = $UpstreamCommit
    generatedAt  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
}
# manifest.json 只被本流水线的脚本消费：统一写成「UTF-8 无 BOM」。
# [坑] 同一句 Set-Content -Encoding UTF8 在 PS 5.1 会写 BOM、在 PS 7 不写 ——
#      行为随宿主版本漂移，故一律走 .NET 显式编码，两个宿主落盘字节完全一致。
[IO.File]::WriteAllText((Join-Path $WorkDir 'manifest.json'),
                        ($manifest | ConvertTo-Json -Depth 5),
                        (New-Object Text.UTF8Encoding($false)))
Log "manifest.json 已生成: build=$build arch=$arch edition=$($br.edition) family=$($br.family -join ',')"

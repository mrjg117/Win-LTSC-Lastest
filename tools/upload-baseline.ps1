<#
.SYNOPSIS 一次性上传官方 LTSC ISO 分卷到本仓库 baseline Release
.DESCRIPTION 本机运行一次（ISO 字节在你机器上，agent 沙箱无法代传）。
             计算并展示 SHA256（你核对微软/来源公示值后填入 config.yml），
             7z 分卷（≤1.9GiB 规避 Release 2GiB 单文件硬限），上传到 baseline Release。
             认证：本机已 `gh auth login` 自动用会话；或设 $env:GITHUB_TOKEN（仅 repo 权限 PAT）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $IsoPath,   # 官方 LTSC ISO 绝对路径
    [Parameter(Mandatory)] [string] $Branch,    # 19044 / 26100
    [int] $ChunkMiB = 1900,
    [string] $Repo = "",                         # owner/repo；留空则从 git remote 推断
    [string] $Token = $env:GITHUB_TOKEN
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $IsoPath)) { throw "ISO 不存在: $IsoPath" }

# 推断 Repo
if (-not $Repo) {
    $url = (git remote get-url origin 2>$null)
    if ($url -match 'github\.com[:/](.+?)(?:\.git)?$') { $Repo = $Matches[1] }
}
if (-not $Repo) { throw "无法推断 Repo，请用 -Repo owner/repo" }

# 认证
if ($Token) { $env:GH_TOKEN = $Token }

# 1) SHA256 展示（务必核对）
$hash = (Get-FileHash $IsoPath -Algorithm SHA256).Hash
Write-Host "=" * 60
Write-Host "ISO SHA256: $hash"
Write-Host ">>> 请核对微软公开值 / 你下载源公示值，一致后再把此值填入 config.yml 的 baseline.sha256.$Branch"
Write-Host "=" * 60

# 2) 7z 分卷（卷名必须含分支号，build_iso.yml 按 *$branch.7z.* 匹配；否则拉基线时找不到）
$base = "baseline-$Branch"
$vol = "$base.7z"
& 7z a -v${ChunkMiB}m $vol $IsoPath
if ($LASTEXITCODE -ne 0) { throw "7z 分卷失败（本机需安装 7-Zip 且在 PATH）" }

# 3) 上传 baseline Release
$assets = Get-ChildItem "$base.7z.*" | ForEach-Object { $_.FullName }
if (-not (gh release view baseline --repo $Repo 2>$null)) {
    gh release create baseline --repo $Repo --title "baseline" `
        --notes "官方 LTSC ISO 分卷（baseline），SHA256 见 config.yml" @assets
} else {
    gh release upload baseline --repo $Repo @assets
}
Write-Host "已上传 $Branch 分卷到 $Repo 的 baseline Release"

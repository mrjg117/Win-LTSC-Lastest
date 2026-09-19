<#
.SYNOPSIS 一次性上传官方 LTSC ISO 分卷到本仓库 baseline Release（RAW 切分，无压缩）
.DESCRIPTION 本机运行一次（ISO 字节在你机器上，agent 沙箱无法代传）。
             计算并展示 SHA256（你核对微软/来源公示值后填入 config.yml），
             RAW 顺序切分（≤1.9GiB/片，无压缩）为 <原版ISO名>.part1/2/3…，
             并生成带哈希的 merge.cmd，一并上传到 baseline Release。
             命名契约：<微软原版ISO名>.part*（build_iso.yml 按 *<isoName>.part* 匹配）。
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

$isoName = @{ "19044" = "zh-cn_windows_10_enterprise_ltsc_2021_x64_dvd_033b7312.iso";
              "26100" = "zh-cn_windows_11_enterprise_ltsc_2024_x64_dvd_cff9cd2d.iso" }[$Branch]
if (-not $isoName) { throw "未知分支: $Branch（仅 19044 / 26100）" }
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

# 2) RAW 顺序切分（与 CI fetch-baseline.py 同契约：<isoName>.part1/2/3…）
$chunk = [long]$ChunkMiB * 1024L * 1024L
$vols = @()
$idx = 1
$fs = [System.IO.File]::OpenRead($IsoPath)
try {
    while ($fs.Position -lt $fs.Length) {
        $part = "$isoName.part$idx"
        $out = [System.IO.File]::Create($part)
        try {
            $written = 0L
            while ($written -lt $chunk -and $fs.Position -lt $fs.Length) {
                $buf = New-Object byte[] (16 * 1024 * 1024)
                $n = $fs.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $chunk - $written))
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $written += $n
            }
        } finally { $out.Close() }
        $vols += $part
        if ($written -lt $chunk) { break }
        $idx++
    }
} finally { $fs.Close() }
Write-Host "已切分 $($vols.Count) 片（≤${ChunkMiB}MiB/片）"

# 3) 生成带哈希的 merge.cmd（用仓库模板）
if (Test-Path "merge.cmd") {
    $tpl = Get-Content "merge.cmd" -Raw
    $expLine = 'set "EXP_' + $isoName + '=' + $hash.ToUpper() + '"'
    $tpl = $tpl -replace '(?s)(REM ===EXPECTED_HASHES_START===).*?(REM ===EXPECTED_HASHES_END===)', ('$1' + [Environment]::NewLine + $expLine + [Environment]::NewLine + '$2')
    Set-Content -Path "merge.cmd.gen" -Value $tpl -NoNewline
    $vols += "merge.cmd.gen"
}

# 4) 上传 baseline Release
if (-not (gh release view baseline --repo $Repo 2>$null)) {
    gh release create baseline --repo $Repo --title "baseline" `
        --notes "官方 LTSC ISO 原版镜像（RAW 切分，SHA256 见 config.yml / merge.cmd）" @vols
} else {
    gh release upload baseline --repo $Repo --clobber @vols
}
Write-Host "已上传 $Branch 分卷到 $Repo 的 baseline Release"

<#
.SYNOPSIS 09 - 读 config.yml 的 postsetup 段，生成 postsetup\postsetup.settings.json
.DESCRIPTION 构建期运行（Patch.cmd 在 08.Bake-Image 之前调用）：
              把用户写在 config.yml 的首启开关（MAS / 关休眠 / 关预留空间 / 虚拟内存 /
              wsreset / 跑完自清）解析为一份 JSON，由 08.Bake-Image 一起烤入 C:\PostSetup；
              首启用 Apply-Settings.ps1 读这份 JSON 执行。改配置不必碰脚本。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\09-gen-postsetup.log"
function Log($m) { "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$cfgPath = Join-Path $WorkDir 'config.yml'
if (-not (Test-Path $cfgPath)) { throw "config.yml 不存在: $cfgPath" }
$text = Get-Content $cfgPath -Raw

# 取 postsetup: 区块（到下一个顶层键或文件尾）
$m = [regex]::Match($text, '(?s)postsetup:\s*\r?\n(.*?)(?=\r?\n[A-Za-z_]+:|$)')
$block = if ($m.Success) { $m.Groups[1].Value } else { '' }

function Get-Val($b, $key) {
    $mm = [regex]::Match($b, "(?m)^\s*$key\s*:\s*(.+?)\s*$")
    if ($mm.Success) { return $mm.Groups[1].Value.Trim().Trim('"') }
    return $null
}
function ToBool($v) { return ($v -eq 'true') }

# pagefile 子区块
$pm = [regex]::Match($block, '(?s)pagefile:\s*\r?\n(.*?)(?=\r?\n\s*[A-Za-z_]+:|$)')
$pb = if ($pm.Success) { $pm.Groups[1].Value } else { '' }
$pageMode = Get-Val $pb 'mode'; if ($null -eq $pageMode) { $pageMode = 'none' }
$fixedMb = Get-Val $pb 'fixed_mb'
if ($null -eq $fixedMb) { $fixedMb = 4096 } else { $fixedMb = [int]$fixedMb }

$clean = ToBool (Get-Val $block 'clean_after_run')
$settings = [ordered]@{
    branch                  = $BranchId
    mas                     = ToBool (Get-Val $block 'mas')
    disable_hibernate       = ToBool (Get-Val $block 'disable_hibernate')
    disable_reserved_storage = ToBool (Get-Val $block 'disable_reserved_storage')
    pagefile                = [ordered]@{ mode = $pageMode; fixed_mb = $fixedMb }
    wsreset                 = ToBool (Get-Val $block 'wsreset')
    clean_after_run         = $clean
}
$outDir = Join-Path $WorkDir 'postsetup'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$settings | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir 'postsetup.settings.json') -Encoding utf8
Log "已生成 postsetup.settings.json: $(($settings | ConvertTo-Json -Compress))"

# clean_after_run=true -> 烤入 .clean.flag，Run-All.ps1 首启跑完自清 C:\PostSetup
if ($clean) {
    New-Item -ItemType File -Force -Path (Join-Path $outDir '.clean.flag') | Out-Null
    Log "已写入 .clean.flag（首启自清）"
}
Log "== postsetup 配置生成完成 =="

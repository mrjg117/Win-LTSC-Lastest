<#
.SYNOPSIS 99 - 强制 W10UI.ini 两行（在调用 W10UI.cmd 之前运行）
.DESCRIPTION 读 delta\win10ui-override.ini 的两行（wim2esd=0 / ResetBase=0），
             确保 W10UI.ini 中这两个关键值到位；不整文件覆盖，免疫上游后续加键。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $WorkDir "logs\99-force-ini.log"
function Log($m){ "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$override = Join-Path $WorkDir 'win10ui-override.ini'
$ini = Join-Path $WorkDir 'W10UI.ini'
if (-not (Test-Path $override)) { Log "FAIL 缺少 override: $override"; throw "缺少 override" }
if (-not (Test-Path $ini)) { Log "FAIL 缺少 W10UI.ini: $ini"; throw "缺少 W10UI.ini" }

# 解析 override 中的键值
$forces = @{}
switch -Regex (Get-Content $override) {
    '^\s*\[.*\]\s*$' { continue }
    '^\s*([^;#][^=]+?)\s*=\s*(.+?)\s*$' {
        $k = $_.Split('=')[0].Trim(); $v = $_.Split('=')[1].Trim()
        if ($k) { $forces[$k] = $v }
    }
}
$lines = Get-Content $ini
$keysHandled = @{}
$newLines = foreach ($line in $lines) {
    $m = [regex]::Match($line, '^\s*([^;#][^=]+?)\s*=\s*(.+?)\s*$')
    if ($m.Success -and $forces.ContainsKey($m.Groups[1].Value.Trim())) {
        $k = $m.Groups[1].Value.Trim()
        $keysHandled[$k] = $true
        "$k=$($forces[$k])"   # 强制覆盖
    } else {
        $line
    }
}
# 追加 override 中存在但 ini 没有的键
foreach ($k in $forces.Keys) {
    if (-not $keysHandled[$k]) { $newLines += "$k=$($forces[$k])" }
}
$newLines | Set-Content $ini
Log "已强制 W10UI.ini: " + ($forces.Keys -join ', ')

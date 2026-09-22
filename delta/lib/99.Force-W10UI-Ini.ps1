<#
.SYNOPSIS 99 - 把「上游 ini 开关」强制写进 W10UI.ini（在调用 W10UI.cmd 之前运行）
.DESCRIPTION 两类值的唯一真相源：
               1) delta\win10ui-override.ini            —— 不随配置变的红线（wim2esd=0 / ResetBase=0）
               2) config.json 的 optimize.ini（由 config.yml 拍平）—— 写了就置 1
             只改这些键的值，不整文件覆盖上游 W10UI.ini，免疫上游后续加键。
  [本脚本只提供逻辑，不含任何具体开关] 开关名全部来自 config.yml 的 optimize.ini，
           执行时逐个核对上游 ini 真有该键 —— 对不上就报错，绝不静默失效。
  [为何自补项不塞进 ini] W10UI.cmd 读 ini 有白名单，未知键会被静默忽略 ——
           所以上游没有的功能一律走 07.Bake-Image 的离线 hive 注入（optimize.registry）。
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

# ---- 读文件一律显式编码，不依赖宿主默认 ----
# [坑] 「Get-Content 不带 -Encoding」的行为随宿主漂移（PS 5.1 默认 ANSI / PS 7 默认 UTF-8），
#      而我们自己的文件是 UTF-8、上游 W10UI.ini 的编码不由我们控制。
#      → 自己的文件用 .NET ReadAllText（自带 BOM 探测）；
#      → 上游 ini 走「ISO-8859-1 字节<->字符 1:1 保真」通道，见下。

# 1) 红线：override.ini 里写什么就强制什么
$forces = @{}
foreach ($line in ([IO.File]::ReadAllText($override) -split "`r?`n")) {
    if ($line -match '^\s*\[.*\]\s*$') { continue }                          # 段头跳过
    $m = [regex]::Match($line, '^\s*([^;#][^=]+?)\s*=\s*(.+?)\s*$')         # 注释行天然不匹配
    if ($m.Success) {
        $k = $m.Groups[1].Value.Trim()
        if ($k) { $forces[$k] = $m.Groups[2].Value.Trim() }                 # 按 '=' 之后的整体取值（值里含 = 也不截断）
    }
}

# 2) 读上游 W10UI.ini（字节保真） + config 写了的 optimize.ini 键 -> 置 1
$latin1 = [Text.Encoding]::GetEncoding(28591)                               # 每个字节 -> 同一码位，往返零损失
$iniText = $latin1.GetString([IO.File]::ReadAllBytes($ini))
$nl = if ($iniText.Contains("`r`n")) { "`r`n" } else { "`n" }               # 沿用原文件换行符
$iniLines = @($iniText -split "`r?`n")
# 末尾换行会在切分后留下一个空元素；先摘掉，「读一遍写一遍」才不会每次多长一空行
if ($iniLines.Count -gt 0 -and $iniLines[-1] -eq '') {
    $iniLines = if ($iniLines.Count -eq 1) { @() } else { @($iniLines[0..($iniLines.Count - 2)]) }
}

$cfg = Get-Content (Join-Path $WorkDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$iniKeys = @($iniLines | ForEach-Object {
    $m = [regex]::Match($_, '^\s*([^;#][^=]+?)\s*=')
    if ($m.Success) { $m.Groups[1].Value.Trim() }
})
# 生效集合 = config.yml 的 optimize.ini（由 config-to-json.py 拍平；未写则为空）
$groupA = @(@($cfg.optimize.ini) | Where-Object { $_ })
# 上游一旦改名/删键，这里必须炸 —— 否则你以为开了、实际没开（静默失效最坏）
$missing = @($groupA | Where-Object { $iniKeys -notcontains $_ })
if ($missing.Count -gt 0) {
    Log "FAIL 上游 W10UI.ini 里没有这些键: $($missing -join ', ')"
    throw "optimize.ini 项在上游 ini 里不存在（上游可能改了键名，请核对 W10UI.ini）"
}
foreach ($name in $groupA) { $forces[$name] = '1' }
Log "optimize.ini 生效 $(if ($groupA.Count) { $groupA -join ', ' } else { '无' })"

# 3) 逐行改写：只覆盖命中键的「值」，保留原行的分隔写法；其余原样；最后补 ini 里没有的键
# [坑·致命] W10UI.cmd 读 ini 靠 :ReadINI 里的 `find /i "<键> "` —— 键后**必须跟至少一个空格**
#   （上游 W10UI.ini 就是 `nosuggapp    =0` 这种「键+空格+=值」写法）。
#   若把整行压成 `nosuggapp=1`，键后没了空格，find 匹配不到该行 -> 变量保持「未定义」；
#   而这些键上游**没给默认值**（见 W10UI.cmd 的默认段，只有 Net35…wim2swm 才有），
#   随后 `if %nosuggapp%==1 (` 就展开成 `if ==1 (` -> cmd 报 `( was unexpected at this time.`
#   -> 整份 W10UI 直接停摆（26100 实测即死在此：VP9 之后那一行）。
#   注：有默认值的键（如 UpdtBootFiles）虽不炸，但会被静默重置为默认 0 —— 同样是「以为开了实际没开」。
#   故只替换「=」之后的值，`键 + 原空格 + =` 原样保留。
$handled = @{}
$newLines = foreach ($line in $iniLines) {
    $m = [regex]::Match($line, '^(\s*([^;#][^=]+?)\s*=)\s*(.*)$')
    if ($m.Success -and $forces.ContainsKey($m.Groups[2].Value.Trim())) {
        $k = $m.Groups[2].Value.Trim()
        $handled[$k] = $true
        $m.Groups[1].Value + [string]$forces[$k]        # 原前缀（含键后空格 + 等号）+ 新值
    } else {
        $line
    }
}
foreach ($k in @($forces.Keys)) {
    # 补键同样必须让键后有一个空格，否则 W10UI 的 `find "<键> "` 依然读不到
    if (-not $handled[$k]) { $newLines += "$k =$($forces[$k])" }
}
# 写回：同一套 latin-1 通道 + 沿用原文件的换行符 —— 未命中行逐字节不变，绝不写 BOM
[IO.File]::WriteAllBytes($ini, $latin1.GetBytes((@($newLines) -join $nl) + $nl))
# [坑] 必须整体加括号：Log "a" + (...) 会被解析成 3 个参数，$m 只拿到 "a"
Log ("已强制 W10UI.ini: " + (@($forces.Keys) -join ', '))

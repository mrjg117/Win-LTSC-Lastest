<#
.SYNOPSIS 00b - 预检：在跑 W10UI 之前秒级暴露所有脚本/配置层面的潜在 bug
.DESCRIPTION 昂贵的 W10UI 集成补丁（~39 分钟）跑在最前，而大部分 bug 藏在它之后的
             自定义步骤里。本步在 W10UI 之前、零镜像挂载地做：
               1) lib\*.ps1 全部 AST 语法解析 + UTF-8 BOM + CRLF 检查
               2) 危险写法扫描：reg.exe add（引号不转义会炸）、PS provider 读离线 hive
                  （句柄泄漏致 unload 失败）、HKLM:\HKLM 重复前缀
               3) config.json 的 optimize.registry 每条：hive 已知 / type 已知 /
                  DWORD·QWORD 值是数字 / path 非空
             所有问题一次性收集、一次性列出；有阻断项才中止（不让 39 分钟白跑才发现）。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkDir,
    [Parameter(Mandatory)] [string] $BranchId
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
$log = Join-Path $WorkDir "logs\00-validate.log"
function Log($m){ $s = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $s; [System.IO.File]::AppendAllText($log, $s + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) }

$issues = @()   # 阻断项：任一存在即中止
$warns  = @()   # 非阻断：仅提示

# ---- 1) 脚本语法 / 编码 / 危险写法 ----
$lib = Join-Path $WorkDir 'lib'
if (-not (Test-Path $lib)) { throw "预检：缺少 lib\ 目录（脚本未就位）" }
foreach ($f in (Get-ChildItem $lib -Filter *.ps1 | Sort-Object Name)) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs.Count) { $issues += "语法错误 $($f.Name): $($errs[0].Message)"; continue }
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $issues += "缺 UTF-8 BOM: $($f.Name)" }
    $txt = [IO.File]::ReadAllText($f.FullName)
    if ($txt -match '(?<!\r)\n') { $warns += "含裸 LF（建议统一 CRLF）: $($f.Name)" }
    # 危险模式扫描跳过 lint 自身：本脚本的报错信息与扫描正则里本就含这些 token，
    # 扫自己必误报；它的职责是扫其余脚本。
    if ($f.Name -ne '00.Validate-Config.ps1') {
        # 先剥掉 # 行注释再扫：避免脚本自身注释里提到这些 token 造成误报
        $code = ($txt -split "`n" | ForEach-Object {
            $i = $_.IndexOf('#')
            if ($i -ge 0) { $_.Substring(0, $i) } else { $_ }
        }) -join "`n"
        # 危险模式：一旦重新引入，CI 里会静默或半静默失败（#27 的元凶就在这两类）
        if ($code -match 'reg\.exe add|reg add ') {
            $issues += "禁止 reg.exe add 写注册表（PS 5.1 不转义内嵌引号 -> 命令语法错）: $($f.Name)"
        }
        if ($code -match 'Get-ChildItem\s+[^\n#]*HKLM:|Get-ItemProperty\s+[^\n#]*HKLM:|Get-Item\s+[^\n#]*HKLM:\\') {
            $issues += "禁止 PS registry provider 读离线 hive（句柄泄漏致 unload Access denied）: $($f.Name)"
        }
        if ($code -match 'HKLM:\\HKLM') { $issues += "HKLM 路径重复前缀 HKLM:\HKLM: $($f.Name)" }
    }
}

# ---- 2) config.json 的注册表项 ----
# [注意] config.json 里 type 是裸名（DWORD/SZ/EXPAND_SZ，由 config-to-json.py 校验）；
#   07 运行时再自己拼 REG_ 前缀。故这里按裸名校验。
$cfgPath = Join-Path $WorkDir 'config.json'
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $knownHives = @('SYSTEM','SOFTWARE','DEFAULT')
    $knownTypes = @('DWORD','SZ','EXPAND_SZ')
    if ($cfg.PSObject.Properties['optimize'] -and $cfg.optimize.PSObject.Properties['registry']) {
        $i = 0
        foreach ($item in @($cfg.optimize.registry)) {
            $i++
            foreach ($put in @($item.puts)) {
                if (-not $put.hive -or $knownHives -notcontains [string]$put.hive) { $issues += "registry[$i] 未知 hive: $($put.hive)"; continue }
                if (-not $put.type -or $knownTypes -notcontains [string]$put.type) { $issues += "registry[$i] 未知/缺 type: $($put.type)"; continue }
                if (-not [string]$put.path -or [string]$put.path -notmatch '\S') { $issues += "registry[$i] path 为空" }
                if ([string]$put.type -eq 'DWORD') {
                    $v = [string]$put.value
                    if (-not ($v -match '^-?\d+$')) { $issues += "registry[$i] DWORD 值不是整数: $v" }
                }
            }
        }
        Log "registry 项校验完成：$i 个配置块"
    }
} else {
    $warns += "config.json 不存在（00 预检应已拦截；本步在其后跑，正常不会到这）"
}

# ---- 汇总 ----
if ($warns.Count) { foreach ($w in $warns) { Log "WARN $w" } }
if ($issues.Count -gt 0) {
    Log "FAIL 预检发现 $($issues.Count) 处阻断问题（一次性列出）："
    foreach ($it in $issues) { Log "  - $it" }
    throw ("预检失败，中止构建（共 $($issues.Count) 处，已在上面一次性列出）")
}
Log "== 预检通过：脚本语法/编码/危险写法 + 配置注册表项全部 OK =="

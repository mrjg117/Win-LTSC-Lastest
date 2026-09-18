# Run-All.ps1 - 首启调度器（由 setupcomplete.cmd 以 SYSTEM 身份调用）
# 顺序执行 C:\PostSetup 下的 .ps1 / .cmd；结尾按 .clean.flag 决定自清。
$ErrorActionPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 先 .ps1（按文件名排序，排除自身）
Get-ChildItem $dir -Filter '*.ps1' |
    Where-Object { $_.Name -ne 'Run-All.ps1' } |
    Sort-Object Name |
    ForEach-Object { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName }

# 再 .cmd
Get-ChildItem $dir -Filter '*.cmd' |
    Sort-Object Name |
    ForEach-Object { & cmd.exe /c $_.FullName }

# 自清：目录内存在 .clean.flag 则删除整个 C:\PostSetup
if (Test-Path (Join-Path $dir '.clean.flag')) {
    Remove-Item $dir -Recurse -Force
}

# Apply-Settings.ps1 - 首启时按 postsetup.settings.json 应用配置（由 Run-All.ps1 调度）
# 所有开关的值来自构建期由 config.yml 生成的 postsetup.settings.json，改配置不必碰本脚本。
$ErrorActionPreference = 'SilentlyContinue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$json = Join-Path $dir 'postsetup.settings.json'
if (-not (Test-Path $json)) { exit 0 }
$s = Get-Content $json -Raw | ConvertFrom-Json

# 关休眠（释放 hiberfil.sys，SSD 友好）
if ($s.disable_hibernate -eq $true) {
    powercfg.exe -h off
}

# 关预留空间
if ($s.disable_reserved_storage -eq $true) {
    # 首启以 SYSTEM 跑在线映像；预留空间需管理员，setupcomplete 即 SYSTEM
    dism.exe /Online /Set-ReservedStorageState /State:Disabled 2>$null
}

# 虚拟内存
if ($s.pagefile -and $s.pagefile.mode -ne 'none') {
    if ($s.pagefile.mode -eq 'system_managed') {
        $cs = Get-WmiObject Win32_ComputerSystem
        $cs.AutomaticManagedPagefile = $true
        $cs.Put() | Out-Null
    } elseif ($s.pagefile.mode -eq 'fixed') {
        $mb = [int]$s.pagefile.fixed_mb
        $cs = Get-WmiObject Win32_ComputerSystem
        $cs.AutomaticManagedPagefile = $false
        $cs.Put() | Out-Null
        $pf = Get-WmiObject -Query "SELECT * FROM Win32_PageFileSetting WHERE Name='C:\\pagefile.sys'" -ErrorAction SilentlyContinue
        if (-not $pf) { $pf = New-Object Win32_PageFileSetting; $pf.Name = 'C:\pagefile.sys' }
        $pf.InitialSize = $mb
        $pf.MaximumSize = $mb
        $pf.Put() | Out-Null
    }
}

# wsreset 重注册 Store（需在线用户会话 + 网络；可选）
if ($s.wsreset -eq $true) {
    Start-Process -FilePath 'wsreset.exe' -ArgumentList '-i' -Wait -ErrorAction SilentlyContinue
}

# MAS 激活（脚本放 postsetup\mas\，true 才运行；MAS 资产由用户自备，本脚本不内置）
if ($s.mas -eq $true) {
    $masDir = Join-Path $dir 'mas'
    if (Test-Path $masDir) {
        Get-ChildItem $masDir -Include *.ps1, *.cmd -Recurse |
            Sort-Object Name |
            ForEach-Object {
                if ($_.Extension -eq '.ps1') { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName }
                else { & cmd.exe /c $_.FullName }
            }
    }
}

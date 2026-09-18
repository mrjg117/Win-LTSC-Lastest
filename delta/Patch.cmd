@echo off
REM ============================================================================
REM Patch.cmd - 总入口（管理员权限 + 编排 A→B→W10UI→E→D）
REM   构建时本文件与 lib/*.ps1、assets、postsetup、config 已整目录拷进上游快照 ./src
REM   调用：Patch.cmd <branchId>   例：Patch.cmd 26100
REM   [SPIKE] W10UI.cmd 的输入/输出约定、本地补丁目录衔接需实机校准（见各步骤注释）
REM ============================================================================
setlocal EnableExtensions EnableDelayedExpansion
set "WORKDIR=%~dp0"
cd /d "%WORKDIR%"

REM ---- 管理员校验 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] 请以管理员身份运行 Patch.cmd
    exit /b 1
)

set "BRANCH=%1"
if "%BRANCH%"=="" set "BRANCH=26100"
set "LOG=%WORKDIR%logs\Patch.log"
echo [%date% %time%] Patch.cmd 开始 branch=%BRANCH% > "%LOG%"

REM ---- 00 预检 fail-fast ----
echo [%date% %time%] [00] 预检 >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\00.Precheck.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 99 强制 W10UI.ini 两行（在 W10UI 前） ----
echo [%date% %time%] [99] 强制 ini >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\99.Force-W10UI-Ini.ps1" -WorkDir "%WORKDIR%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 解压 baseline ISO 到分布文件夹（供 W10UI 集成补丁） ----
echo [%date% %time%] 解压 baseline ISO -> ISO\ >> "%LOG%"
bin\7z.exe x "baseline-%BRANCH%.iso" -o"ISO" -y >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 01 清单（改造A） ----
echo [%date% %time%] [01] Build-Manifest >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\01.Build-Manifest.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 02 下载补丁（改造B） ----
echo [%date% %time%] [02] Fetch-Updates >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\02.Fetch-Updates.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 上游 W10UI.cmd 集成补丁到 install.wim ----
REM [SPIKE] W10UI.cmd 读取分布文件夹 ISO\ 并集成补丁，输出位置假设为 ISO\sources\install.wim。
REM        其是否消费我们 updates\ 下的本地 msu 取决于 W10UI.ini 的更新源配置（需实机校准）。
echo [%date% %time%] 调用 W10UI.cmd 集成补丁 >> "%LOG%"
cmd /c W10UI.cmd >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 03 VC++ 注入（扩展E） ----
echo [%date% %time%] [03] Integrate-VCpp >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\03.Integrate-VCpp.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 04 驱动注入 ----
echo [%date% %time%] [04] Integrate-Drivers >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\04.Integrate-Drivers.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 05 应用预装（仅 Win11） ----
echo [%date% %time%] [05] Integrate-Apps >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\05.Integrate-Apps.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 06 组件精简 ----
echo [%date% %time%] [06] Patch-Components >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\06.Patch-Components.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 07 断言（改造D，失败即中止，不留半成品） ----
echo [%date% %time%] [07] Assert-UBR >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\07.Assert-UBR.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 08 烤入自动应答 + PostSetup ----
echo [%date% %time%] [08] Bake-Image >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\08.Bake-Image.ps1" -WorkDir "%WORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 封装最终 ISO ----
echo [%date% %time%] 封装 ISO >> "%LOG%"
if not exist "out" mkdir out
bin\oscdimg.exe -m -o -u2 -udfver102 ^
  -bootdata:2#p0,e,b"ISO\boot\etfsboot.com"#pEF,e,b"ISO\efi\microsoft\boot\efisys.bin" ^
  "ISO" "out\WinLTSC-%BRANCH%.iso" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo [%date% %time%] 完成 -> out\WinLTSC-%BRANCH%.iso >> "%LOG%"
exit /b 0

:fail
echo [FATAL] 构建失败，详见 %LOG%
exit /b 1

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

REM ---- 传给 PowerShell 的 WorkDir 必须去掉尾部反斜杠 ----
REM [关键] Windows 命令行解析(CommandLineToArgvW) 把 \" 视为转义引号：
REM        -WorkDir "D:\x\src\" 的结束引号会被吃掉，其后 -BranchId "26100"
REM        被吞进同一个参数 -> 脚本报 "missing mandatory parameters: BranchId"。
REM        故另存一份去掉尾部反斜杠的 PSWORKDIR 专供 -File 传参；
REM        WORKDIR 仍保留尾部反斜杠用于 "%WORKDIR%logs\..." 之类的路径拼接。
set "PSWORKDIR=%WORKDIR:~0,-1%"
if "%PSWORKDIR%"=="" set "PSWORKDIR=%WORKDIR%"

REM ---- 管理员校验 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] 请以管理员身份运行 Patch.cmd
    exit /b 1
)

set "BRANCH=%1"
if "%BRANCH%"=="" set "BRANCH=26100"

REM ---- 确保 logs 目录存在 ----
REM [关键] cmd 的 >> 重定向失败会导致该行命令被完全跳过（不执行、不留痕），
REM        必须先建目录，否则所有脚本静默不跑且拿不到任何诊断。
if not exist "%WORKDIR%logs" mkdir "%WORKDIR%logs"
if not exist "%WORKDIR%logs" (
    echo [ERROR] 无法创建 logs 目录：%WORKDIR%logs
    exit /b 1
)
set "LOG=%WORKDIR%logs\Patch.log"
echo [%date% %time%] Patch.cmd 开始 branch=%BRANCH% > "%LOG%"

REM ---- 00 预检 fail-fast ----
echo [%date% %time%] [00] 预检 >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\00.Precheck.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 99 强制 W10UI.ini 两行（在 W10UI 前） ----
echo [%date% %time%] [99] 强制 ini >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\99.Force-W10UI-Ini.ps1" -WorkDir "%PSWORKDIR%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 解压 baseline ISO 到分布文件夹（供 W10UI 集成补丁） ----
echo [%date% %time%] 解压 baseline ISO -> ISO\ >> "%LOG%"
bin\7z.exe x "baseline-%BRANCH%.iso" -o"ISO" -y >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
REM ---- 释放磁盘：已解压，原 ISO 不再需要（runner D: 仅约 14GB）----
del /f /q "baseline-%BRANCH%.iso" >> "%LOG%" 2>&1

REM ---- 01 清单（改造A） ----
echo [%date% %time%] [01] Build-Manifest >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\01.Build-Manifest.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 02 下载补丁（改造B） ----
echo [%date% %time%] [02] Fetch-Updates >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\02.Fetch-Updates.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 02b 用上游 meta4(Metalink) 下载补丁到 patch\ ----
REM W10UI.cmd 自身不下载更新，只集成 Repo(=%cd%\patch) 下已有的补丁；
REM patch\ 为空则 cmd_repo=0，等于没打补丁。此步照抄上游 Start.cmd 的 [4/4]。
echo [%date% %time%] [02b] Fetch-Updates-Meta4 >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\02b.Fetch-Updates-Meta4.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 上游 W10UI.cmd 集成补丁到 install.wim ----
REM [SPIKE] W10UI.cmd 读取分布文件夹 ISO\ 并集成补丁，输出位置假设为 ISO\sources\install.wim。
REM        其是否消费我们 updates\ 下的本地 msu 取决于 W10UI.ini 的更新源配置（需实机校准）。
echo [%date% %time%] 调用 W10UI.cmd 集成补丁 >> "%LOG%"
cmd /c W10UI.cmd >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
REM ---- 释放磁盘 ----
REM 1) W10UI 自己封装的 ISO（约 7.9GB）与最终结果无关：后续 oscdimg 会基于 ISO\ 重新封装
REM 2) patch\ 里的补丁包已集成进 install.wim，不再需要
del /f /q *.iso >> "%LOG%" 2>&1
if exist "patch" rmdir /s /q "patch"

REM ---- 03 VC++ 注入（扩展E） ----
echo [%date% %time%] [03] Integrate-VCpp >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\03.Integrate-VCpp.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 04 驱动注入 ----
echo [%date% %time%] [04] Integrate-Drivers >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\04.Integrate-Drivers.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 05 应用预装（仅 Win11） ----
echo [%date% %time%] [05] Integrate-Apps >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\05.Integrate-Apps.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 06 组件精简 ----
echo [%date% %time%] [06] Patch-Components >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\06.Patch-Components.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 07 断言（改造D，失败即中止，不留半成品） ----
echo [%date% %time%] [07] Assert-UBR >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\07.Assert-UBR.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

REM ---- 08 烤入自动应答 + PostSetup ----
echo [%date% %time%] [08] Bake-Image >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\08.Bake-Image.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%" >> "%LOG%" 2>&1
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
REM ---- 失败时把完整日志打到 stdout，否则 Actions 里看不到任何线索 ----
if exist "%LOG%" (
    echo ---- Patch.log 开始 ----
    type "%LOG%"
    echo ---- Patch.log 结束 ----
) else (
    echo [WARN] 日志文件不存在: %LOG%
)
exit /b 1

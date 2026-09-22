@echo off
REM ============================================================================
REM Patch.cmd - 总入口（管理员权限 + 编排 A→B→W10UI→E→D）
REM   构建时本文件与 lib/*.ps1、assets、config 已整目录拷进上游快照 ./src
REM   调用：Patch.cmd <branchId>   例：Patch.cmd 26100
REM
REM [输出约定 · 核心] 本脚本**一律不重定向**：每条命令的 stdout/stderr 直通控制台。
REM   目的：本地双击运行时命令窗里看到什么，CI（.github/workflows/build_iso.yml）
REM   里就原样显示什么。工作流那步由**父进程**统一接管：
REM       cmd.exe /c "Patch.cmd <branch> > logs\Patch.log 2>&1"
REM   再增量跟随 logs\Patch.log（5s 一轮 + 心跳）打着进 Actions 日志 ——
REM   于是「命令窗内容 == Patch.log 内容 == web 上看到的内容」三者一致。
REM   ⚠ 绝对不要给下面的命令再加 `>> "%LOG%" 2>&1` 之类：那会把命令窗整个掏空，
REM     web 上只剩一片空白（历史上正是这么踩的），而且中途没有任何进度可看。
REM   ⚠ 本文件不再自建 logs\Patch.log；聚合日志的两条出口：本地=命令窗（要存盘就
REM     自己 `Patch.cmd 26100 > build.log 2>&1`），CI=父进程那条重定向。
REM   ⚠ 编码：本文件是 UTF-8（带 BOM）且含中文 echo，控制台输出码页须为 65001 才不
REM     乱码。码页由**父进程**设定（CI 的 pwsh 步骤里 chcp；本地可在窗口里先 chcp）。
REM     **不要在本文件里 chcp** —— 批处理执行中途改码页会让 cmd 的行偏移错位，
REM     已知会跳行或重复执行语句。
REM   ⚠ 各 lib\*.ps1 的 Log() 自带 HH:mm:ss 时间戳，并各自写 logs\NN-*.log（双轨）。
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
REM [关键] lib\*.ps1 的 Log() 往 %WORKDIR%logs\*.log 里写；目录不在，那些脚本会在
REM        第一行写日志时就抛异常中止。故必须先建。
if not exist "%WORKDIR%logs" mkdir "%WORKDIR%logs"
if not exist "%WORKDIR%logs" (
    echo [ERROR] 无法创建 logs 目录：%WORKDIR%logs
    exit /b 1
)
echo [%date% %time%] Patch.cmd 开始 branch=%BRANCH%

REM ---- 00 预检 fail-fast ----
echo [%date% %time%] [00] 预检
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\00.Precheck.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail

REM ---- 99 强制 W10UI.ini 两行（在 W10UI 前） ----
echo [%date% %time%] [99] 强制 ini
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\99.Force-W10UI-Ini.ps1" -WorkDir "%PSWORKDIR%"
if errorlevel 1 goto :fail

REM ---- 解压 baseline ISO 到分布文件夹（供 W10UI 集成补丁） ----
echo [%date% %time%] 解压 baseline ISO -> ISO\
bin\7z.exe x "baseline-%BRANCH%.iso" -o"ISO" -y
if errorlevel 1 goto :fail
REM 注意：baseline-<分支>.iso 此刻**不能删**——01.Build-Manifest 还要从它里提取
REM       sources\install.wim 做 DISM /Get-WimInfo 识别 build/arch。

REM ---- 01 清单（改造A） ----
echo [%date% %time%] [01] Build-Manifest
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\01.Build-Manifest.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail
REM ---- 释放磁盘 ----
REM 01 已识别完 build/arch，baseline ISO（~5GB）与其解出的 install.wim（~4.5GB）都不再需要
del /f /q "baseline-%BRANCH%.iso"
if exist "iso-extract" rmdir /s /q "iso-extract"

REM ---- 02 下载补丁到 patch\（上游 meta4 / Metalink） ----
REM W10UI.cmd 自身不下载更新，只集成 Repo(=%cd%\patch) 下已有的补丁；
REM patch\ 为空则 cmd_repo=0，等于没打补丁，故此步是必需环节。
echo [%date% %time%] [02] Fetch-Updates
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\02.Fetch-Updates.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail

REM ---- 上游 W10UI.cmd 集成补丁到 install.wim ----
REM [SPIKE] W10UI.cmd 读取分布文件夹 ISO\ 并集成补丁，输出位置假设为 ISO\sources\install.wim。
REM        其是否消费我们 updates\ 下的本地 msu 取决于 W10UI.ini 的更新源配置（需实机校准）。
echo [%date% %time%] 调用 W10UI.cmd 集成补丁
cmd /c W10UI.cmd
if errorlevel 1 goto :fail
REM ---- 释放磁盘 ----
REM 1) W10UI 自己封装的 ISO（约 7.9GB）与最终结果无关：后续 oscdimg 会基于 ISO\ 重新封装
REM 2) patch\ 里的补丁包已集成进 install.wim，不再需要
del /f /q *.iso
if exist "patch" rmdir /s /q "patch"

REM ---- 03 驱动注入 ----
echo [%date% %time%] [03] Integrate-Drivers
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\03.Integrate-Drivers.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail

REM ---- 04 应用预置（按 config.yml 的 apps 清单） ----
echo [%date% %time%] [04] Integrate-Apps
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\04.Integrate-Apps.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail

REM ---- 05 组件精简（按 config.yml 的 remove 清单） ----
echo [%date% %time%] [05] Patch-Components
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\05.Patch-Components.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail

REM ---- 06 断言（失败即中止，不留半成品） ----
echo [%date% %time%] [06] Assert-UBR
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\06.Assert-UBR.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail

REM ---- 07 烤入镜像（SKU 转 IoT + 离线优化注入 + 应答 + C:\Tools） ----
echo [%date% %time%] [07] Bake-Image
powershell -NoProfile -ExecutionPolicy Bypass -File "%WORKDIR%lib\07.Bake-Image.ps1" -WorkDir "%PSWORKDIR%" -BranchId "%BRANCH%"
if errorlevel 1 goto :fail

REM ---- 封装最终 ISO ----
echo [%date% %time%] 封装 ISO
if not exist "out" mkdir out
bin\oscdimg.exe -m -o -u2 -udfver102 ^
  -bootdata:2#p0,e,b"ISO\boot\etfsboot.com"#pEF,e,b"ISO\efi\microsoft\boot\efisys.bin" ^
  "ISO" "out\WinLTSC-%BRANCH%.iso"
if errorlevel 1 goto :fail

echo [%date% %time%] 完成 -> out\WinLTSC-%BRANCH%.iso
exit /b 0

:fail
REM 失败时不再 type 日志文件：上面每一步的原始输出已经全部在控制台/CI 日志里了
echo [FATAL] 构建失败 —— 上方输出即完整现场（CI 里同时存于 logs\Patch.log）
exit /b 1

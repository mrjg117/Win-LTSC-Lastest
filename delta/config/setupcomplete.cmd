@echo off
REM ============================================================================
REM setupcomplete.cmd - 首启薄引导（以 SYSTEM 身份跑一次）
REM   由 Windows 安装最终化阶段自动调用；不建计划任务、不建服务。
REM   职责：调 C:\PostSetup\Run-All.ps1 -> 兜底清 Panther\unattend.xml -> 自删。
REM ============================================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PostSetup\Run-All.ps1"

REM 兜底清理 unattend（系统通常在 specialize 后已自删；精简镜像下确保干净）
if exist "C:\Windows\Panther\unattend.xml" del /f /q "C:\Windows\Panther\unattend.xml"
if exist "C:\Windows\Panther\Unattend" rmdir /s /q "C:\Windows\Panther\Unattend"

REM 自删本引导（Windows 不会自动删自定义脚本）
del /f /q "%~f0"

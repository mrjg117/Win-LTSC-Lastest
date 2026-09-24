@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM 注：不启用 chcp 65001 —— 在 UTF-8 代码页下 for /f 解析 certutil 输出会异常（rc=255）；
REM     且哈希行纯 ASCII，skip=1 取第二行即可，与系统语言无关。
REM ============================================================================
REM merge.cmd - RAW split merge + SHA256 verify (universal)
REM   Usage: drop this file next to the files it should verify.
REM     - Split upload:  *.part1/*.part2/...  -> copy /b rebuild + SHA256 verify
REM     - Single upload: *.iso                -> SHA256 verify only (no merge needed)
REM   It auto-finds the inputs and verifies SHA256 against the embedded expected
REM   hash below. Works whether or not the ISO was split at upload time.
REM   Expected hashes are filled at build time; format: set "EXP_<fullISOName>=<SHA256 upper>"
REM ============================================================================

REM ===EXPECTED_HASHES_START===
set "EXP___ISO___=___HASH___"
REM ===EXPECTED_HASHES_END===

goto :main

:main
pushd "%~dp0"
set "OK=0"
set "BAD=0"

REM 探测分片：用 dir /b 经 for /f 探测，避免通配符无匹配时 cmd 把字面量当一次迭代。
set "HAVE_PART=0"
for /f "tokens=*" %%F in ('dir /b /a-d *.part1 2^>nul') do set "HAVE_PART=1"

REM 有分片 -> 合并重建；否则 -> 当作单文件上传直接校验（扁平结构，避免 else 内嵌套 if/for 触发 cmd 解析 bug）。
if %HAVE_PART%==1 goto :do_split
goto :do_single


:do_split
for %%F in (*.part1) do (
    call :merge "%%~nF"
)
goto :decide


:do_single
set "HAVE_ISO=0"
for /f "tokens=*" %%F in ('dir /b /a-d *.iso 2^>nul') do set "HAVE_ISO=1"
if %HAVE_ISO%==1 (
    for %%F in (*.iso) do (
        call :verify "%%~nxF"
    )
)


:decide
echo.
if %BAD% gtr 0 goto :do_fail
if %OK% gtr 0 goto :do_ok
echo [X] No *.part1 or *.iso files found. Put merge.cmd beside the files.
popd
endlocal & exit /b 1

:do_ok
echo [OK] All %OK% ISO hash-verified.
popd
endlocal & exit /b 0

:do_fail
echo [FAIL] %BAD% mismatch(es), %OK% passed.
popd
endlocal & exit /b 1


:merge
set "BASE=%~1"
echo.
echo === Rebuild: %BASE% ===
set "PARTS="
for /f "tokens=*" %%P in ('dir /b /a-d "%BASE%.part*" 2^>nul ^| sort') do (
    if defined PARTS ( set "PARTS=!PARTS!+""%%P""" ) else ( set "PARTS=""%%P""" )
)
if not defined PARTS (
    echo   [X] No split files for %BASE%
    set /a BAD+=1
    goto :eof
)
copy /b %PARTS% "%BASE%" >nul
if errorlevel 1 (
    echo   [X] copy /b rebuild failed
    set /a BAD+=1
    goto :eof
)
REM 重组完成后复用校验例程（按重建出的 %BASE% 文件名比对期望哈希）
call :verify "%BASE%"
goto :eof


:verify
set "NAME=%~1"
echo.
echo === Verify: %NAME% ===
set "EXP=!EXP_%NAME%!"
if not defined EXP (
    echo   [X] No expected hash for %NAME% - check EXPECTED_HASHES block
    set /a BAD+=1
    goto :eof
)
set "ACT="
for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "%NAME%" SHA256 2^>nul') do (
    if not defined ACT set "ACT=%%H"
)
if not defined ACT (
    echo   [X] certutil hash failed
    set /a BAD+=1
    goto :eof
)
if /i "!ACT!"=="!EXP!" (
    echo   [OK] SHA256 match: %NAME%
    set /a OK+=1
) else (
    echo   [X] SHA256 MISMATCH
    echo        expected: !EXP!
    echo        actual:   !ACT!
    set /a BAD+=1
)
goto :eof

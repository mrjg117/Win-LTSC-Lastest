@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions EnableDelayedExpansion
REM ============================================================================
REM merge.cmd - RAW split merge + SHA256 verify (universal)
REM   Usage: drop this file next to *.part1/*.part2/... in the same folder, run it.
REM   It auto-finds every *.part1, rebuilds the full ISO by same-name prefix via
REM   copy /b, then verifies SHA256 against the embedded expected hash below.
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

for %%F in (*.part1) do (
    call :merge "%%~nF"
)

echo.
if %BAD%==0 (
    if %OK%==0 (
        echo [!] No *.part1 split files found. Put merge.cmd beside the volumes.
        popd
        exit /b 1
    )
    echo [OK] All %OK% ISO(s) hash-verified.
    popd
    exit /b 0
)
echo [FAIL] %BAD% mismatch(es), %OK% passed.
popd
exit /b 1


:merge
set "BASE=%~1"
echo.
echo === Rebuild: %BASE% ===
set "PARTS="
for /f "tokens=*" %%P in ('dir /b /a-d "%BASE%.part*" 2^>nul ^| sort') do (
    if defined PARTS ( set "PARTS=!PARTS!+""%%P""" ) else ( set "PARTS=""%%P""" )
)
if not defined PARTS (
    echo   [!] No split files for %BASE%
    set /a BAD+=1
    goto :eof
)
copy /b %PARTS% "%BASE%" >nul
if errorlevel 1 (
    echo   [!] copy /b rebuild failed
    set /a BAD+=1
    goto :eof
)
set "ACT="
for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "%BASE%" SHA256 2^>nul') do (
    if not defined ACT set "ACT=%%H"
)
if not defined ACT (
    echo   [!] certutil hash failed
    set /a BAD+=1
    goto :eof
)
set "EXP=!EXP_%BASE%!"
if not defined EXP (
    echo   [!] No expected hash for %BASE% (check EXPECTED_HASHES block)
    set /a BAD+=1
    goto :eof
)
if /i "!ACT!"=="!EXP!" (
    echo   [OK] SHA256 match: %BASE%
    set /a OK+=1
) else (
    echo   [!] SHA256 MISMATCH!
    echo        expected: !EXP!
    echo        actual:   !ACT!
    set /a BAD+=1
)
goto :eof

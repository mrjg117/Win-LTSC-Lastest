@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM NOTE: do NOT enable chcp 65001 - under UTF-8 codepage, for /f parsing of certutil
REM       output breaks (rc=255). Hash lines are pure ASCII, skip=1 takes the 2nd
REM       line, independent of system language. All runtime echo is ASCII on purpose
REM       (Chinese would mojibake under the default 936 codepage and can even be
REM       misparsed as commands). Verification results are also written to a file.
REM ============================================================================
REM merge.cmd - RAW split merge + SHA256 verify (universal)
REM   Usage: drop this file next to the files it should verify.
REM     - Split upload:  *.part1/*.part2/...  -> copy /b rebuild + SHA256 verify
REM     - Single upload: *.iso                -> SHA256 verify only (no merge needed)
REM   It auto-finds the inputs and verifies SHA256 against the embedded expected
REM   hash below. Works whether or not the ISO was split at upload time.
REM   Expected hashes are filled at build time; format: set "EXP_<fullISOName>=<SHA256 upper>"
REM ----------------------------------------------------------------------------
REM   Improvements (per request):
REM     1) During merge, show which part is being merged (N/total) so it does not
REM        look frozen; 2) show "computing SHA256, please wait" before verify;
REM     3) do NOT auto-close on finish - show the conclusion and write a full
REM        report to merge-result.txt (the verification result document).
REM ============================================================================

REM ===EXPECTED_HASHES_START===
set "EXP___ISO___=___HASH___"
REM ===EXPECTED_HASHES_END===

goto :main

:main
pushd "%~dp0"
set "OK=0"
set "BAD=0"
set "RESULT=%~dp0merge-result.txt"
echo [%time%] merge.cmd started > "%RESULT%"
echo [%time%] working dir: %~dp0 >> "%RESULT%"

REM detect split files via dir /b + for /f (avoids the literal-glob iteration bug
REM when no *.part1 exists).
set "HAVE_PART=0"
for /f "tokens=*" %%F in ('dir /b /a-d *.part1 2^>nul') do set "HAVE_PART=1"

REM have splits -> rebuild; otherwise -> single-file verify (flat structure avoids
REM the else-with-nested-if/for cmd parser crash).
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
echo [X] No *.part1 or *.iso files found. >> "%RESULT%"
echo. >> "%RESULT%"
echo === SUMMARY === >> "%RESULT%"
echo checked: 0   passed: 0   failed: 0 >> "%RESULT%"
echo.
echo [i] Result written to: %RESULT%
echo [i] Press any key to exit ...
pause >nul
popd
endlocal & exit /b 1

:do_ok
echo [OK] All %OK% ISO hash-verified.
echo [OK] All %OK% ISO hash-verified. >> "%RESULT%"
echo. >> "%RESULT%"
echo === SUMMARY === >> "%RESULT%"
echo checked: %OK%   passed: %OK%   failed: 0 >> "%RESULT%"
echo.
echo [i] Result written to: %RESULT%
echo [i] Press any key to exit ...
pause >nul
popd
endlocal & exit /b 0

:do_fail
echo [FAIL] %BAD% mismatch(es), %OK% passed.
echo [FAIL] %BAD% mismatch(es), %OK% passed. >> "%RESULT%"
echo. >> "%RESULT%"
echo === SUMMARY === >> "%RESULT%"
echo checked: %OK%   passed: %OK%   failed: %BAD% >> "%RESULT%"
echo.
echo [i] Result written to: %RESULT%
echo [i] Press any key to exit ...
pause >nul
popd
endlocal & exit /b 1


:merge
set "BASE=%~1"
echo.
echo === Rebuild: %BASE% ===
echo === Rebuild: %BASE% === >> "%RESULT%"
REM count parts first for progress display
set "TOTAL=0"
for /f "tokens=*" %%P in ('dir /b /a-d "%BASE%.part*" 2^>nul ^| sort') do set /a TOTAL+=1
if %TOTAL%==0 (
    echo   [X] No split files for %BASE%
    echo   [X] No split files for %BASE% >> "%RESULT%"
    set /a BAD+=1
    goto :eof
)
echo   [*] Found %TOTAL% parts, merging in order:
echo   [*] Found %TOTAL% parts, merging in order: >> "%RESULT%"
for /f "tokens=*" %%P in ('dir /b /a-d "%BASE%.part*" 2^>nul ^| sort') do (
    echo     - %%P
    echo     - %%P >> "%RESULT%"
)
echo   [*] Merging %TOTAL% parts into %BASE% via binary copy /b (may take a while) ...
echo   [*] Merging %TOTAL% parts into %BASE% ... >> "%RESULT%"
set "N=0"
set "FIRST=1"
for /f "tokens=*" %%P in ('dir /b /a-d "%BASE%.part*" 2^>nul ^| sort') do (
    set /a N+=1
    echo   [+] merging part !N!/%TOTAL%: %%P
    echo   [+] merging part !N!/%TOTAL%: %%P >> "%RESULT%"
    if !FIRST!==1 (
        copy /b "%%P" "%BASE%" >nul
        if errorlevel 1 (
            echo   [X] merge failed at part !N!: %%P
            echo   [X] merge failed at part !N!: %%P >> "%RESULT%"
            set /a BAD+=1
            goto :eof
        )
        set "FIRST=0"
    ) else (
        copy /b "%BASE%"+"%%P" "%BASE%.tmp" >nul
        if errorlevel 1 (
            echo   [X] merge failed at part !N!: %%P
            echo   [X] merge failed at part !N!: %%P >> "%RESULT%"
            set /a BAD+=1
            goto :eof
        )
        move /y "%BASE%.tmp" "%BASE%" >nul
    )
)
echo   [+] all !N! parts merged; verifying next ...
echo   [+] all !N! parts merged >> "%RESULT%"
REM after rebuild, reuse the verify routine (match expected hash by rebuilt name)
call :verify "%BASE%"
goto :eof


:verify
set "NAME=%~1"
echo.
echo === Verify: %NAME% ===
echo === Verify: %NAME% === >> "%RESULT%"
set "EXP="
REM lookup expected hash by name without nested expansion (set EXP_ enumerates
REM all EXPECTED_HASHES entries; match the one named EXP_<ISOName>).
for /f "tokens=1,* delims==" %%A in ('set EXP_ 2^>nul') do (
    if /i "%%A"=="EXP_%NAME%" set "EXP=%%B"
)
if not defined EXP (
    echo   [X] No expected hash for %NAME% - check EXPECTED_HASHES block
    echo   [X] No expected hash for %NAME% >> "%RESULT%"
    set /a BAD+=1
    goto :eof
)
echo   [*] Computing SHA256 of %NAME% (large file may take tens of seconds, please wait) ...
echo   [*] Computing SHA256 of %NAME% ... >> "%RESULT%"
set "ACT="
for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "%NAME%" SHA256 2^>nul') do (
    if not defined ACT set "ACT=%%H"
)
if not defined ACT (
    echo   [X] certutil hash failed
    echo   [X] certutil hash failed >> "%RESULT%"
    set /a BAD+=1
    goto :eof
)
if /i "!ACT!"=="!EXP!" (
    echo   [OK] SHA256 match: %NAME%
    echo   [OK] SHA256 match: %NAME% >> "%RESULT%"
    set /a OK+=1
) else (
    echo   [X] SHA256 MISMATCH
    echo        expected: !EXP!
    echo        actual:   !ACT!
    echo   [X] SHA256 MISMATCH >> "%RESULT%"
    echo        expected: !EXP! >> "%RESULT%"
    echo        actual:   !ACT! >> "%RESULT%"
    set /a BAD+=1
)
goto :eof

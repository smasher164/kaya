@echo off
rem Analyze the newest crash dump in C:\kaya\dumps with cdb (stored
rem exception context + stacks + !analyze -v) and write the report to
rem out_analyze.txt. Requires the Windows SDK Debugging Tools.
rem
rem TRAP (learned 2026-07-15): enabledelayedexpansion eats the literal
rem exclamation marks that cdb commands are made of (!analyze became
rem 'nalyze'). This script deliberately avoids delayed expansion; keep
rem it that way.
set OUT=C:\kaya\out_analyze.txt
del %OUT% 2>nul
set NEWEST=
for /f "delims=" %%f in ('dir /b /o-d C:\kaya\dumps\*.dmp 2^>nul') do (
    set NEWEST=%%f
    goto found
)
:found
if "%NEWEST%"=="" (
    echo NO-DUMPS > %OUT%
    echo ANALYZEDONE >> %OUT%
    exit /b 1
)
echo ===DUMP %NEWEST%=== > %OUT%
"C:\Program Files (x86)\Windows Kits\10\Debuggers\arm64\cdb.exe" ^
    -y "srv*C:\kaya\sym*https://msdl.microsoft.com/download/symbols" ^
    -z "C:\kaya\dumps\%NEWEST%" ^
    -c ".ecxr; kc 40; !analyze -v; q" >> %OUT% 2>&1
echo ANALYZEDONE >> %OUT%

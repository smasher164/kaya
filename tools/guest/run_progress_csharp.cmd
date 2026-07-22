@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=progress
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem ms-appx resolves against the PROCESS exe's directory: run the
rem APPHOST exe (not dotnet.exe) with kaya's minimal resources.pri
rem beside it.
dotnet build --nologo -v q -o C:\kaya\cs-out > C:\kaya\out_progress_csharp.txt 2>&1
if errorlevel 1 goto done
copy /y C:\kaya\resources.pri C:\kaya\cs-out\resources.pri > nul
C:\kaya\cs-out\kaya-guests.exe >> C:\kaya\out_progress_csharp.txt 2>&1
:done
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_progress_csharp.txt

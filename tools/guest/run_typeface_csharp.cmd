@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
rem The vendored font's bytes are what the guest hands the backend, and
rem THIS is the leg that cannot do without the absolute path: its cwd is
rem C:\kaya\cs, where the guests' repo-relative default would resolve to
rem C:\kaya\cs\guests\assets\fonts and miss.
set KAYA_FONT_FILE=C:\kaya\guests\assets\fonts\sora-wght.ttf
set KAYA_SELFTEST=typeface
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem ms-appx resolves against the PROCESS exe's directory: the
rem APPHOST exe (not dotnet.exe) runs from C:\kaya\cs-out, built
rem ONCE at deploy with kaya's minimal resources.pri beside it (the
rem per-leg builds raced the shared obj\ and cs-out, CS2012).
C:\kaya\cs-out\kaya-guests.exe > C:\kaya\out_typeface_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_csharp.txt

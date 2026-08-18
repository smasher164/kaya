@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
rem The vendored mark's bytes are what the guest declares; named
rem absolutely so no leg depends on its cwd (deploy-win.sh ships it to
rem the repo-mirror path, the vendored font's rule one asset over).
set KAYA_ICON_FILE=C:\kaya\guests\assets\icons\kaya-mark.png
set KAYA_SELFTEST=identity
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem ms-appx resolves against the PROCESS exe's directory: the
rem APPHOST exe (not dotnet.exe) runs from C:\kaya\cs-out, built
rem ONCE at deploy with kaya's minimal resources.pri beside it (the
rem per-leg builds raced the shared obj\ and cs-out, CS2012).
C:\kaya\cs-out\kaya-guests.exe > C:\kaya\out_identity_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_csharp.txt

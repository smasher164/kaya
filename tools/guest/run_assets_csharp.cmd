@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
rem NO ASSET LINE HERE, and on THIS scene that is the whole
rem point: the guest names two assets and reads no path and no
rem environment variable, and the census it freezes is of the
rem root the deploy staged and named machine-wide in
rem KAYA_ASSET_DIR. A per-asset variable in a per-leg launcher
rem is what made every new asset cost five more of these lines.
set KAYA_SELFTEST=assets
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem ms-appx resolves against the PROCESS exe's directory: the
rem APPHOST exe (not dotnet.exe) runs from C:\kaya\cs-out, built
rem ONCE at deploy with kaya's minimal resources.pri beside it (the
rem per-leg builds raced the shared obj\ and cs-out, CS2012).
C:\kaya\cs-out\kaya-guests.exe > C:\kaya\out_assets_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_assets_csharp.txt

@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
rem NO ASSET LINE HERE ANY MORE: the guest names the mark
rem `asset("icons/kaya-mark.png")` and the core resolves it out
rem of the root the deploy stages and names machine-wide in
rem KAYA_ASSET_DIR — the typeface scene's rule, one asset over.
set KAYA_SELFTEST=identity
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem ms-appx resolves against the PROCESS exe's directory: the
rem APPHOST exe (not dotnet.exe) runs from C:\kaya\cs-out, built
rem ONCE at deploy with kaya's minimal resources.pri beside it (the
rem per-leg builds raced the shared obj\ and cs-out, CS2012).
C:\kaya\cs-out\kaya-guests.exe > C:\kaya\out_identity_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_csharp.txt

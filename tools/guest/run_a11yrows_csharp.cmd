@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\a11yrows_csharp 2>nul
mkdir C:\kaya\legs\a11yrows_csharp\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\a11yrows_csharp\state
set KAYA_SELFTEST=a11yrows
set KAYA_VERB_TRACE=C:\kaya\flightrec\a11yrows_csharp-vtrace.txt
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem ms-appx resolves against the PROCESS exe's directory: the
rem APPHOST exe (not dotnet.exe) runs from C:\kaya\cs-out, built
rem ONCE at deploy with kaya's minimal resources.pri beside it (the
rem per-leg builds raced the shared obj\ and cs-out, CS2012).
C:\kaya\cs-out\kaya-guests.exe > C:\kaya\out_a11yrows_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_a11yrows_csharp.txt

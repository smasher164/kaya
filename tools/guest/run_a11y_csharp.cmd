@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once; every act one EMPTIES that tree, so a pooled
rem neighbour's open SQLite went readonly under it. Cleared here, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\a11y_csharp 2>nul
mkdir C:\kaya\legs\a11y_csharp\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\a11y_csharp\state
set KAYA_SELFTEST=a11y
set KAYA_VERB_TRACE=C:\kaya\flightrec\a11y_csharp-vtrace.txt
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem ms-appx resolves against the PROCESS exe's directory: the
rem APPHOST exe (not dotnet.exe) runs from C:\kaya\cs-out, built
rem ONCE at deploy with kaya's minimal resources.pri beside it (the
rem per-leg builds raced the shared obj\ and cs-out, CS2012).
C:\kaya\cs-out\kaya-guests.exe > C:\kaya\out_a11y_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_a11y_csharp.txt

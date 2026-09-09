@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\feed_csharp 2>nul
mkdir C:\kaya\legs\feed_csharp\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\feed_csharp\state
set KAYA_SELFTEST=feed
set KAYA_VERB_TRACE=C:\kaya\flightrec\feed_csharp-vtrace.txt
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem Built ONCE at deploy (per-leg dotnet run raced the shared
rem obj\bin four-wide, CS2012); the apphost exe keeps the
rem process name kaya-guests.exe for the kill sweep.
C:\kaya\cs\bin\Debug\net10.0\kaya-guests.exe > C:\kaya\out_feed_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_feed_csharp.txt

@echo off
cd /d C:\kaya\cs
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=todos
set DOTNET_CLI_TELEMETRY_OPTOUT=1
rem Built ONCE at deploy (per-leg dotnet run raced the shared
rem obj\bin four-wide, CS2012); the apphost exe keeps the
rem process name kaya-guests.exe for the kill sweep.
C:\kaya\cs\bin\Debug\net10.0\kaya-guests.exe > C:\kaya\out_todos_csharp.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_csharp.txt

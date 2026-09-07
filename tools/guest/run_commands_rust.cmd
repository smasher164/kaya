@echo off
cd /d C:\kaya
set KAYA_SELFTEST=commands
set KAYA_VERB_TRACE=C:\kaya\flightrec\commands_rust-vtrace.txt
commands.exe > C:\kaya\out_commands_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_commands_rust.txt

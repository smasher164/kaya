@echo off
cd /d C:\kaya
set KAYA_SELFTEST=commands
commands.exe > C:\kaya\out_commands_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_commands_rust.txt

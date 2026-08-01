@echo off
cd /d C:\kaya
set KAYA_SELFTEST=stall
stall.exe > C:\kaya\out_stall_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_stall_rust.txt

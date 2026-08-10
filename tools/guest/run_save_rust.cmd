@echo off
cd /d C:\kaya
set KAYA_SELFTEST=save
save.exe > C:\kaya\out_save_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_save_rust.txt

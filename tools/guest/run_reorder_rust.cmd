@echo off
cd /d C:\kaya
set KAYA_SELFTEST=reorder
reorder.exe > C:\kaya\out_reorder_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_reorder_rust.txt

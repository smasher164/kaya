@echo off
cd /d C:\kaya
set KAYA_SELFTEST=listdetail
listdetail.exe > C:\kaya\out_listdetail_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_listdetail_rust.txt

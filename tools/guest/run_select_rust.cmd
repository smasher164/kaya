@echo off
cd /d C:\kaya
set KAYA_SELFTEST=select
select.exe > C:\kaya\out_select_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_select_rust.txt

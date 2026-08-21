@echo off
cd /d C:\kaya
set KAYA_SELFTEST=table
table.exe > C:\kaya\out_table_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_table_rust.txt

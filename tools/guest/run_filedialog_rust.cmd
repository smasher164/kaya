@echo off
cd /d C:\kaya
set KAYA_SELFTEST=filedialog
filedialog.exe > C:\kaya\out_filedialog_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_filedialog_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=progress
progress.exe > C:\kaya\out_progress_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_progress_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=dirty
dirty.exe > C:\kaya\out_dirty_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_dirty_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=grow
grow.exe > C:\kaya\out_grow_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_grow_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=panels
panels.exe > C:\kaya\out_panels_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_panels_rust.txt

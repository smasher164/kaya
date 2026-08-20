@echo off
cd /d C:\kaya
set KAYA_SELFTEST=panes
panes.exe > C:\kaya\out_panes_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_panes_rust.txt

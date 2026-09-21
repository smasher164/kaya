@echo off
cd /d C:\kaya\sheetprobe
set KAYA_SHEET_PROBE=1
sheetprobe.exe > C:\kaya\sheetprobe\out.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\sheetprobe\out.txt

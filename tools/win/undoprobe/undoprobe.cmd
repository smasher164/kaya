@echo off
cd /d C:\kaya\undoprobe
set KAYA_UNDO_PROBE=1
undoprobe.exe > C:\kaya\undoprobe\out.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\undoprobe\out.txt

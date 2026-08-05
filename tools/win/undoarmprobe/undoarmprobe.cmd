@echo off
cd /d C:\kaya\undoarmprobe
set KAYA_UNDO_ARM_PROBE=1
undo.exe > C:\kaya\undoarmprobe\out.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\undoarmprobe\out.txt

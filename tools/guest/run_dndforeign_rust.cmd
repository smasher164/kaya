@echo off
cd /d C:\kaya
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\dnd-witness.ps1 -Direction in > C:\kaya\out_dndforeign_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_dndforeign_rust.txt

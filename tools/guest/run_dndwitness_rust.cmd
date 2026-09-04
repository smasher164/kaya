@echo off
cd /d C:\kaya
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\dnd-witness.ps1 -Direction out > C:\kaya\out_dndwitness_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_dndwitness_rust.txt

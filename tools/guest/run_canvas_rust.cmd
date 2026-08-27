@echo off
cd /d C:\kaya
set KAYA_SELFTEST=canvas
canvas.exe > C:\kaya\out_canvas_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_canvas_rust.txt

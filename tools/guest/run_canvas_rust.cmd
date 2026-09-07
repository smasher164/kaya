@echo off
cd /d C:\kaya
set KAYA_SELFTEST=canvas
set KAYA_VERB_TRACE=C:\kaya\flightrec\canvas_rust-vtrace.txt
canvas.exe > C:\kaya\out_canvas_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_canvas_rust.txt

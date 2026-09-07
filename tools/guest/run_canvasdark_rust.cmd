@echo off
cd /d C:\kaya
set KAYA_APPEARANCE=dark
set KAYA_SELFTEST=canvas
set KAYA_VERB_TRACE=C:\kaya\flightrec\canvasdark_rust-vtrace.txt
canvas.exe > C:\kaya\out_canvasdark_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_canvasdark_rust.txt

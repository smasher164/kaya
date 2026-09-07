@echo off
cd /d C:\kaya
set KAYA_SELFTEST=window
set KAYA_VERB_TRACE=C:\kaya\flightrec\window_rust-vtrace.txt
window.exe > C:\kaya\out_window_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_window_rust.txt

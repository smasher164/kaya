@echo off
cd /d C:\kaya
set KAYA_SELFTEST=adaptive
set KAYA_VERB_TRACE=C:\kaya\flightrec\adaptive_rust-vtrace.txt
adaptive.exe > C:\kaya\out_adaptive_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_adaptive_rust.txt

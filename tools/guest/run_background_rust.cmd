@echo off
cd /d C:\kaya
set KAYA_SELFTEST=background
set KAYA_VERB_TRACE=C:\kaya\flightrec\background_rust-vtrace.txt
background.exe > C:\kaya\out_background_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_background_rust.txt

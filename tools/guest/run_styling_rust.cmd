@echo off
cd /d C:\kaya
set KAYA_SELFTEST=styling
set KAYA_VERB_TRACE=C:\kaya\flightrec\styling_rust-vtrace.txt
styling.exe > C:\kaya\out_styling_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_styling_rust.txt

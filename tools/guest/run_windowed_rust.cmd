@echo off
cd /d C:\kaya
set KAYA_SELFTEST=windowed
set KAYA_VERB_TRACE=C:\kaya\flightrec\windowed_rust-vtrace.txt
windowed.exe > C:\kaya\out_windowed_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_windowed_rust.txt

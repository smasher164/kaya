@echo off
cd /d C:\kaya
set KAYA_SELFTEST=radio
set KAYA_VERB_TRACE=C:\kaya\flightrec\radio_rust-vtrace.txt
radio.exe > C:\kaya\out_radio_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_radio_rust.txt

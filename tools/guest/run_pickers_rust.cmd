@echo off
cd /d C:\kaya
set KAYA_SELFTEST=pickers
set KAYA_VERB_TRACE=C:\kaya\flightrec\pickers_rust-vtrace.txt
pickers.exe > C:\kaya\out_pickers_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_pickers_rust.txt

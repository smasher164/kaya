@echo off
cd /d C:\kaya
set KAYA_SELFTEST=confirm
set KAYA_VERB_TRACE=C:\kaya\flightrec\confirm_rust-vtrace.txt
confirm.exe > C:\kaya\out_confirm_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_confirm_rust.txt

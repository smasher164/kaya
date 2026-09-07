@echo off
cd /d C:\kaya
set KAYA_SELFTEST=textarea
set KAYA_VERB_TRACE=C:\kaya\flightrec\textarea_rust-vtrace.txt
textarea.exe > C:\kaya\out_textarea_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_textarea_rust.txt

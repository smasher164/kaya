@echo off
cd /d C:\kaya
set KAYA_SELFTEST=save
set KAYA_VERB_TRACE=C:\kaya\flightrec\save_rust-vtrace.txt
save.exe > C:\kaya\out_save_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_save_rust.txt

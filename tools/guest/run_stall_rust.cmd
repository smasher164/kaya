@echo off
cd /d C:\kaya
set KAYA_SELFTEST=stall
set KAYA_VERB_TRACE=C:\kaya\flightrec\stall_rust-vtrace.txt
stall.exe > C:\kaya\out_stall_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_stall_rust.txt

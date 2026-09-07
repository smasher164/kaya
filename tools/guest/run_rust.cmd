@echo off
cd /d C:\kaya
set KAYA_SELFTEST=1
set KAYA_VERB_TRACE=C:\kaya\flightrec\rust-vtrace.txt
milestone2.exe > C:\kaya\out_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=ranges
set KAYA_VERB_TRACE=C:\kaya\flightrec\ranges_rust-vtrace.txt
ranges.exe > C:\kaya\out_ranges_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_ranges_rust.txt

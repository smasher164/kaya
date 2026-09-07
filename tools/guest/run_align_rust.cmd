@echo off
cd /d C:\kaya
set KAYA_SELFTEST=align
set KAYA_VERB_TRACE=C:\kaya\flightrec\align_rust-vtrace.txt
align.exe > C:\kaya\out_align_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_align_rust.txt

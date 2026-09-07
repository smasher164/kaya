@echo off
cd /d C:\kaya
set KAYA_SELFTEST=progress
set KAYA_VERB_TRACE=C:\kaya\flightrec\progress_rust-vtrace.txt
progress.exe > C:\kaya\out_progress_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_progress_rust.txt

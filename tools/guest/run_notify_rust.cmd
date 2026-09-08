@echo off
cd /d C:\kaya
set KAYA_SELFTEST=notify
set KAYA_VERB_TRACE=C:\kaya\flightrec\notify_rust-vtrace.txt
notify.exe > C:\kaya\out_notify_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_notify_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=a11yrows
set KAYA_VERB_TRACE=C:\kaya\flightrec\a11yrows_rust-vtrace.txt
a11yrows.exe > C:\kaya\out_a11yrows_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_a11yrows_rust.txt

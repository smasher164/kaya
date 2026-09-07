@echo off
cd /d C:\kaya
set KAYA_SELFTEST=nav
set KAYA_VERB_TRACE=C:\kaya\flightrec\nav_rust-vtrace.txt
nav.exe > C:\kaya\out_nav_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_nav_rust.txt

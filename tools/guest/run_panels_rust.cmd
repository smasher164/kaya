@echo off
cd /d C:\kaya
set KAYA_SELFTEST=panels
set KAYA_VERB_TRACE=C:\kaya\flightrec\panels_rust-vtrace.txt
panels.exe > C:\kaya\out_panels_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_panels_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=toolbar
set KAYA_VERB_TRACE=C:\kaya\flightrec\toolbar_rust-vtrace.txt
toolbar.exe > C:\kaya\out_toolbar_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_toolbar_rust.txt

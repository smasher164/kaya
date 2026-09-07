@echo off
cd /d C:\kaya
set KAYA_SELFTEST=tooltips
set KAYA_VERB_TRACE=C:\kaya\flightrec\tooltips_rust-vtrace.txt
tooltips.exe > C:\kaya\out_tooltips_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_tooltips_rust.txt

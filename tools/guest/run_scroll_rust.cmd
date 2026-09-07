@echo off
cd /d C:\kaya
set KAYA_SELFTEST=scroll
set KAYA_VERB_TRACE=C:\kaya\flightrec\scroll_rust-vtrace.txt
scroll.exe > C:\kaya\out_scroll_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_scroll_rust.txt

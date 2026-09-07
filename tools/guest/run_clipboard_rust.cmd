@echo off
cd /d C:\kaya
set KAYA_SELFTEST=clipboard
set KAYA_VERB_TRACE=C:\kaya\flightrec\clipboard_rust-vtrace.txt
clipboard.exe > C:\kaya\out_clipboard_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_clipboard_rust.txt

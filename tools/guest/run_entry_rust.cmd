@echo off
cd /d C:\kaya
set KAYA_SELFTEST=entry
set KAYA_VERB_TRACE=C:\kaya\flightrec\entry_rust-vtrace.txt
entry.exe > C:\kaya\out_entry_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_entry_rust.txt

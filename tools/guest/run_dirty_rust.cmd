@echo off
cd /d C:\kaya
set KAYA_SELFTEST=dirty
set KAYA_VERB_TRACE=C:\kaya\flightrec\dirty_rust-vtrace.txt
dirty.exe > C:\kaya\out_dirty_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_dirty_rust.txt

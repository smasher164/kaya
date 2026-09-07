@echo off
cd /d C:\kaya
set KAYA_SELFTEST=grow
set KAYA_VERB_TRACE=C:\kaya\flightrec\grow_rust-vtrace.txt
grow.exe > C:\kaya\out_grow_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_grow_rust.txt

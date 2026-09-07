@echo off
cd /d C:\kaya
set KAYA_SELFTEST=dnd
set KAYA_VERB_TRACE=C:\kaya\flightrec\dnd_rust-vtrace.txt
dnd.exe > C:\kaya\out_dnd_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_dnd_rust.txt

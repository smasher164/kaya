@echo off
cd /d C:\kaya
set KAYA_SELFTEST=panes
set KAYA_VERB_TRACE=C:\kaya\flightrec\panes_rust-vtrace.txt
panes.exe > C:\kaya\out_panes_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_panes_rust.txt

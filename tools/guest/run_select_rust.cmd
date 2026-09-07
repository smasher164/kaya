@echo off
cd /d C:\kaya
set KAYA_SELFTEST=select
set KAYA_VERB_TRACE=C:\kaya\flightrec\select_rust-vtrace.txt
select.exe > C:\kaya\out_select_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_select_rust.txt

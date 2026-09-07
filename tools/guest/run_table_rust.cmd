@echo off
cd /d C:\kaya
set KAYA_SELFTEST=table
set KAYA_VERB_TRACE=C:\kaya\flightrec\table_rust-vtrace.txt
table.exe > C:\kaya\out_table_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_table_rust.txt

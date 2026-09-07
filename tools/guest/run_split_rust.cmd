@echo off
cd /d C:\kaya
set KAYA_SELFTEST=split
set KAYA_VERB_TRACE=C:\kaya\flightrec\split_rust-vtrace.txt
split.exe > C:\kaya\out_split_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_split_rust.txt

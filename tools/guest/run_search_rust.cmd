@echo off
cd /d C:\kaya
set KAYA_SELFTEST=search
set KAYA_VERB_TRACE=C:\kaya\flightrec\search_rust-vtrace.txt
search.exe > C:\kaya\out_search_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_search_rust.txt

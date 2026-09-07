@echo off
cd /d C:\kaya
set KAYA_SELFTEST=search
search.exe > C:\kaya\out_search_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_search_rust.txt

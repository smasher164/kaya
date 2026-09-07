@echo off
cd /d C:\kaya
set KAYA_SELFTEST=menus
set KAYA_VERB_TRACE=C:\kaya\flightrec\menus_rust-vtrace.txt
menus.exe > C:\kaya\out_menus_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_menus_rust.txt

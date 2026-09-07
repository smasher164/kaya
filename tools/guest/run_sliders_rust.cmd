@echo off
cd /d C:\kaya
set KAYA_SELFTEST=sliders
set KAYA_VERB_TRACE=C:\kaya\flightrec\sliders_rust-vtrace.txt
sliders.exe > C:\kaya\out_sliders_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_sliders_rust.txt

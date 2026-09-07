@echo off
cd /d C:\kaya
set KAYA_SELFTEST=sizepolicy
set KAYA_VERB_TRACE=C:\kaya\flightrec\sizepolicy_rust-vtrace.txt
sizepolicy.exe > C:\kaya\out_sizepolicy_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_sizepolicy_rust.txt

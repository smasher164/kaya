@echo off
cd /d C:\kaya
set KAYA_SELFTEST=layout
set KAYA_VERB_TRACE=C:\kaya\flightrec\layout_rust-vtrace.txt
layout.exe > C:\kaya\out_layout_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_layout_rust.txt

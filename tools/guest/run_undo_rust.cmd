@echo off
cd /d C:\kaya
set KAYA_SELFTEST=undo
set KAYA_VERB_TRACE=C:\kaya\flightrec\undo_rust-vtrace.txt
undo.exe > C:\kaya\out_undo_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_undo_rust.txt

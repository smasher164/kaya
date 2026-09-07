@echo off
cd /d C:\kaya
set KAYA_SELFTEST=filedialog
set KAYA_VERB_TRACE=C:\kaya\flightrec\filedialog_rust-vtrace.txt
filedialog.exe > C:\kaya\out_filedialog_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_filedialog_rust.txt

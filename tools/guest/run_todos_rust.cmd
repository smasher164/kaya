@echo off
cd /d C:\kaya
set KAYA_SELFTEST=todos
set KAYA_VERB_TRACE=C:\kaya\flightrec\todos_rust-vtrace.txt
todos.exe > C:\kaya\out_todos_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_rust.txt

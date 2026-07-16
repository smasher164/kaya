@echo off
cd /d C:\kaya
set KAYA_SELFTEST=todos
todos.exe > C:\kaya\out_todos_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_rust.txt

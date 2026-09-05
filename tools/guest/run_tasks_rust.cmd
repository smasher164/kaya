@echo off
cd /d C:\kaya
set KAYA_SELFTEST=tasks
tasks.exe > C:\kaya\out_tasks_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_tasks_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=undo
undo.exe > C:\kaya\out_undo_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_undo_rust.txt

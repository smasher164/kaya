@echo off
cd /d C:\kaya
set KAYA_SELFTEST=split
split.exe > C:\kaya\out_split_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_split_rust.txt

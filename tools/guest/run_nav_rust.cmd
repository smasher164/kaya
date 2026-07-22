@echo off
cd /d C:\kaya
set KAYA_SELFTEST=nav
nav.exe > C:\kaya\out_nav_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_nav_rust.txt

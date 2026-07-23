@echo off
cd /d C:\kaya
set KAYA_SELFTEST=sections
sections.exe > C:\kaya\out_sections_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_sections_rust.txt

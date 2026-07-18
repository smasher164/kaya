@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=entry
python C:\kaya\entry.py > C:\kaya\out_entry_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_entry_python.txt

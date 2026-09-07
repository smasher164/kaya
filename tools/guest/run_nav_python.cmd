@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=nav
set KAYA_VERB_TRACE=C:\kaya\flightrec\nav_python-vtrace.txt
python C:\kaya\nav.py > C:\kaya\out_nav_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_nav_python.txt

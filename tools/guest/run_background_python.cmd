@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=background
set KAYA_VERB_TRACE=C:\kaya\flightrec\background_python-vtrace.txt
python C:\kaya\background.py > C:\kaya\out_background_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_background_python.txt

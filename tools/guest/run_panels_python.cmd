@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=panels
set KAYA_VERB_TRACE=C:\kaya\flightrec\panels_python-vtrace.txt
python C:\kaya\panels.py > C:\kaya\out_panels_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_panels_python.txt

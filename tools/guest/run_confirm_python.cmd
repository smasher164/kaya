@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=confirm
set KAYA_VERB_TRACE=C:\kaya\flightrec\confirm_python-vtrace.txt
python C:\kaya\confirm.py > C:\kaya\out_confirm_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_confirm_python.txt

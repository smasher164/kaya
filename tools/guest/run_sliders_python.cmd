@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=sliders
set KAYA_VERB_TRACE=C:\kaya\flightrec\sliders_python-vtrace.txt
python C:\kaya\sliders.py > C:\kaya\out_sliders_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_sliders_python.txt

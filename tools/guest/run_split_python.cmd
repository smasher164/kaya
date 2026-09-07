@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=split
set KAYA_VERB_TRACE=C:\kaya\flightrec\split_python-vtrace.txt
python C:\kaya\split.py > C:\kaya\out_split_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_split_python.txt

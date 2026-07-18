@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=1
python C:\kaya\milestone2.py > C:\kaya\out_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_python.txt

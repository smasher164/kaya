@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=grow
python C:\kaya\grow.py > C:\kaya\out_grow_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_grow_python.txt

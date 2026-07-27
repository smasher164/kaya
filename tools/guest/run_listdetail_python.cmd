@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=listdetail
python C:\kaya\split.py > C:\kaya\out_listdetail_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_listdetail_python.txt

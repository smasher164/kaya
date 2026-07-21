@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=align
python C:\kaya\align.py > C:\kaya\out_align_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_align_python.txt

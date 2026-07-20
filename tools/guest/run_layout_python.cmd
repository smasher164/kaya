@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=layout
python C:\kaya\layout.py > C:\kaya\out_layout_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_layout_python.txt

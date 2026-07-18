@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=todos
python C:\kaya\todos.py > C:\kaya\out_todos_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_python.txt

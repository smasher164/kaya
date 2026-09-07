@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=todos
set KAYA_VERB_TRACE=C:\kaya\flightrec\todos_python-vtrace.txt
python C:\kaya\todos.py > C:\kaya\out_todos_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_python.txt

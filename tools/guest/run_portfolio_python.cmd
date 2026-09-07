@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=portfolio
set KAYA_VERB_TRACE=C:\kaya\flightrec\portfolio_python-vtrace.txt
python C:\kaya\portfolio.py > C:\kaya\out_portfolio_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_portfolio_python.txt

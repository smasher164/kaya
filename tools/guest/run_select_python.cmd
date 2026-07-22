@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
set KAYA_SELFTEST=select
rem ms-appx (XamlControlsResources) resolves against the PROCESS
rem exe's directory: place kaya's minimal resources.pri beside
rem python.exe (idempotent; inert for non-WinUI python programs).
copy /y C:\kaya\resources.pri "C:\Users\Akhil\AppData\Local\Programs\Python\Python313-arm64\resources.pri" > nul
python C:\kaya\select.py > C:\kaya\out_select_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_select_python.txt

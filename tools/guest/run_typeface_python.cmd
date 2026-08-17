@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
rem The vendored font's bytes are what the guest hands the backend;
rem named absolutely so no leg depends on its cwd (deploy-win.sh ships
rem it to the repo-mirror path).
set KAYA_FONT_FILE=C:\kaya\guests\assets\fonts\sora-wght.ttf
set KAYA_SELFTEST=typeface
rem ms-appx (XamlControlsResources) resolves against the PROCESS
rem exe's directory: place kaya's minimal resources.pri beside
rem python.exe (idempotent; inert for non-WinUI python programs).
copy /y C:\kaya\resources.pri "C:\Users\Akhil\AppData\Local\Programs\Python\Python313-arm64\resources.pri" > nul
python C:\kaya\typeface.py > C:\kaya\out_typeface_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_python.txt

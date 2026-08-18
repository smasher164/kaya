@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
rem The vendored mark's bytes are what the guest declares; named
rem absolutely so no leg depends on its cwd (deploy-win.sh ships it to
rem the repo-mirror path, the vendored font's rule one asset over).
set KAYA_ICON_FILE=C:\kaya\guests\assets\icons\kaya-mark.png
set KAYA_SELFTEST=identity
rem ms-appx (XamlControlsResources) resolves against the PROCESS
rem exe's directory: place kaya's minimal resources.pri beside
rem python.exe (idempotent; inert for non-WinUI python programs).
copy /y C:\kaya\resources.pri "C:\Users\Akhil\AppData\Local\Programs\Python\Python313-arm64\resources.pri" > nul
python C:\kaya\identity.py > C:\kaya\out_identity_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_python.txt

@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
rem NO ASSET LINE HERE ANY MORE: the guest names the mark
rem `asset("icons/kaya-mark.png")` and the core resolves it out
rem of the root the deploy stages and names machine-wide in
rem KAYA_ASSET_DIR — the typeface scene's rule, one asset over.
set KAYA_SELFTEST=identity
rem ms-appx (XamlControlsResources) resolves against the PROCESS
rem exe's directory: place kaya's minimal resources.pri beside
rem python.exe (idempotent; inert for non-WinUI python programs).
copy /y C:\kaya\resources.pri "C:\Users\Akhil\AppData\Local\Programs\Python\Python313-arm64\resources.pri" > nul
python C:\kaya\identity.py > C:\kaya\out_identity_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_python.txt

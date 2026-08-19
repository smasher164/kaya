@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
rem NO ASSET LINE HERE, and on THIS scene that is the whole
rem point: the guest names two assets and reads no path and no
rem environment variable, and the census it freezes is of the
rem root the deploy staged and named machine-wide in
rem KAYA_ASSET_DIR. A per-asset variable in a per-leg launcher
rem is what made every new asset cost five more of these lines.
set KAYA_SELFTEST=assets
rem ms-appx (XamlControlsResources) resolves against the PROCESS
rem exe's directory: place kaya's minimal resources.pri beside
rem python.exe (idempotent; inert for non-WinUI python programs).
copy /y C:\kaya\resources.pri "C:\Users\Akhil\AppData\Local\Programs\Python\Python313-arm64\resources.pri" > nul
python C:\kaya\assets.py > C:\kaya\out_assets_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_assets_python.txt

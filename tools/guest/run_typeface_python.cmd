@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set PYTHONPATH=C:\kaya\bindings\python
rem NO ASSET LINE HERE, and that is the change: `asset(name)`
rem resolves the vendored font in the core, out of the root the
rem deploy stages and names machine-wide in KAYA_ASSET_DIR. A
rem per-asset variable in a per-leg launcher is what made every
rem new asset cost five more of these lines.
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\typeface_python 2>nul
mkdir C:\kaya\legs\typeface_python\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\typeface_python\state
set KAYA_SELFTEST=typeface
set KAYA_VERB_TRACE=C:\kaya\flightrec\typeface_python-vtrace.txt
rem ms-appx (XamlControlsResources) resolves against the PROCESS
rem exe's directory: place kaya's minimal resources.pri beside
rem python.exe (idempotent; inert for non-WinUI python programs).
copy /y C:\kaya\resources.pri "C:\Users\Akhil\AppData\Local\Programs\Python\Python313-arm64\resources.pri" > nul
python C:\kaya\typeface.py > C:\kaya\out_typeface_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_python.txt

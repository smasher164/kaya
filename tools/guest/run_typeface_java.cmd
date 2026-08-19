@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
rem NO ASSET LINE HERE, and that is the change: `asset(name)`
rem resolves the vendored font in the core, out of the root the
rem deploy stages and names machine-wide in KAYA_ASSET_DIR. A
rem per-asset variable in a per-leg launcher is what made every
rem new asset cost five more of these lines.
set KAYA_SELFTEST=typeface
rem ms-appx resolves against the PROCESS exe's directory: place
rem kaya's minimal resources.pri beside java.exe (idempotent).
copy /y C:\kaya\resources.pri "C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot\bin\resources.pri" > nul
java -cp C:\kaya\java\classes dev.kaya.milestone2kt.Main > C:\kaya\out_typeface_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_java.txt

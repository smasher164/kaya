@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
rem The vendored mark's bytes are what the guest declares; named
rem absolutely so no leg depends on its cwd (deploy-win.sh ships it to
rem the repo-mirror path, the vendored font's rule one asset over).
set KAYA_ICON_FILE=C:\kaya\guests\assets\icons\kaya-mark.png
set KAYA_SELFTEST=identity
rem ms-appx resolves against the PROCESS exe's directory: place
rem kaya's minimal resources.pri beside java.exe (idempotent).
copy /y C:\kaya\resources.pri "C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot\bin\resources.pri" > nul
java -cp C:\kaya\java\classes dev.kaya.milestone2kt.Main > C:\kaya\out_identity_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_java.txt

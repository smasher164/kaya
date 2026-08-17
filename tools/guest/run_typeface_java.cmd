@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
rem The vendored font's bytes are what the guest hands the backend;
rem named absolutely so no leg depends on its cwd (deploy-win.sh ships
rem it to the repo-mirror path).
set KAYA_FONT_FILE=C:\kaya\guests\assets\fonts\sora-wght.ttf
set KAYA_SELFTEST=typeface
rem ms-appx resolves against the PROCESS exe's directory: place
rem kaya's minimal resources.pri beside java.exe (idempotent).
copy /y C:\kaya\resources.pri "C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot\bin\resources.pri" > nul
java -cp C:\kaya\java\classes dev.kaya.milestone2kt.Main > C:\kaya\out_typeface_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_java.txt

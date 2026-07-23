@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=sections
rem ms-appx resolves against the PROCESS exe's directory: place
rem kaya's minimal resources.pri beside java.exe (idempotent).
copy /y C:\kaya\resources.pri "C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot\bin\resources.pri" > nul
java -cp C:\kaya\java\classes dev.kaya.milestone2kt.Main > C:\kaya\out_sections_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_sections_java.txt

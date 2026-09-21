@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
rem docs/tasks-s4-plan.md P7
rmdir /s /q C:\kaya\legs\save_java 2>nul
mkdir C:\kaya\legs\save_java\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\save_java\state
set KAYA_SELFTEST=save
set KAYA_VERB_TRACE=C:\kaya\flightrec\save_java-vtrace.txt
for /f "delims=" %%J in ('where java') do copy /y C:\kaya\resources.pri "%%~dpJresources.pri" >nul
java -cp C:\kaya\java\classes dev.kaya.guests.Main > C:\kaya\out_save_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_save_java.txt

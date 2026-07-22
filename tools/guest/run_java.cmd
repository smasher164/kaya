@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=1
java -cp C:\kaya\java\classes dev.kaya.milestone2kt.Main > C:\kaya\out_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_java.txt

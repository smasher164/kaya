@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=listdetail
java -cp C:\kaya\java\classes dev.kaya.guests.Main > C:\kaya\out_listdetail_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_listdetail_java.txt

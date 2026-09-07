@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=background
set KAYA_VERB_TRACE=C:\kaya\flightrec\background_java-vtrace.txt
java -cp C:\kaya\java\classes dev.kaya.guests.Main > C:\kaya\out_background_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_background_java.txt

@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=todos
set KAYA_VERB_TRACE=C:\kaya\flightrec\todos_java-vtrace.txt
java -cp C:\kaya\java\classes dev.kaya.guests.Main > C:\kaya\out_todos_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_todos_java.txt

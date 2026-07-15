@echo off
rem Capture a full dump of a HUNG (not crashed) process by image name
rem (%1, without .exe) via cdb attach, into C:\kaya\dumps where
rem analyze-dump.cmd will find it as the newest dump. Kills the hung
rem process afterward. No delayed expansion here — it eats cdb's '!'.
set OUT=C:\kaya\out_hangdump.txt
del %OUT% 2>nul
"C:\Program Files (x86)\Windows Kits\10\Debuggers\arm64\cdb.exe" ^
    -pn %1.exe ^
    -c ".dump /ma C:\kaya\dumps\hang-%1.dmp; qd" > %OUT% 2>&1
taskkill /f /im %1.exe >nul 2>&1
echo HANGDUMPDONE >> %OUT%

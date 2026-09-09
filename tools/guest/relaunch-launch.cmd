@echo off
rem The schtasks stub for the second act's PLAIN door (docs/tasks-s4-plan.md P5):
rem %1 the leg, %2 the exe under C:\kaya, %3 the declared id.
rem THE CONSOLE SESSION IS THE POINT, relaunch-com.cmd's reason exactly: a
rem WinUI process needs a window station, and an ssh session is session 0
rem (docs/traps.md).
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\relaunch-launch.ps1 -Leg "%~1" -Exe "%~2" -Id "%~3" > C:\kaya\out_%~1-act2.txt 2>&1
echo RELAUNCHEXIT=%ERRORLEVEL% >> C:\kaya\out_%~1-act2.txt

@echo off
rem The schtasks stub for the second act's door (docs/tasks-s9-plan.md R6):
rem %1 the leg, %2 the braced class id, %3 the AUMID, %4 the launch
rem argument KEY, %5 the notification id, %6 the declared id, %7 the package
rem family (or "-" when unpackaged). THE KEY AND THE ID ARRIVE SEPARATELY
rem because `=` is an argument delimiter here (docs/tasks-s9-plan.md; the
rem lane module says the same).
rem THE CONSOLE SESSION IS THE POINT: COM starts a LocalServer32 in the
rem CALLER's session, so the process act two runs in gets its window station
rem from this task and not from ssh (docs/traps.md, "ssh has no window
rem station"; measured 2026-09-08, session 1 with a window).
set KAYA_RELAUNCH_FAMILY=%~7
if "%~7"=="-" set KAYA_RELAUNCH_FAMILY=
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\relaunch-com.ps1 -Leg "%~1" -Clsid "%~2" -Aumid "%~3" -Key "%~4" -Notification "%~5" -Id "%~6" -Family "%KAYA_RELAUNCH_FAMILY%" > C:\kaya\out_%~1-act2.txt 2>&1
echo RELAUNCHEXIT=%ERRORLEVEL% >> C:\kaya\out_%~1-act2.txt

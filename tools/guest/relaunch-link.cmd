@echo off
rem The schtasks stub for the second act's LINK door (docs/app-links-plan.md
rem L5): %1 the leg, %2 the exe under C:\kaya the registered scheme must
rem start, %3 the declared id.
rem THE URL IS NOT AN ARGUMENT HERE. `=` is an argument delimiter in a .cmd's
rem %1..%9 and `&` is a cmd operator, so a link with a query cannot ride one
rem (measured 2026-09-09); the runner writes it to
rem C:\kaya\legs\%1\relaunch-url.txt and the .ps1 reads it.
rem THE CONSOLE SESSION IS THE POINT, relaunch-launch.cmd's reason exactly: a
rem WinUI process needs a window station, and an ssh session is session 0
rem (docs/traps.md).
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\relaunch-link.ps1 -Leg "%~1" -Exe "%~2" -Id "%~3" > C:\kaya\out_%~1-act2.txt 2>&1
echo RELAUNCHEXIT=%ERRORLEVEL% >> C:\kaya\out_%~1-act2.txt

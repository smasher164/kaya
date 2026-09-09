@echo off
rem The notification readiness probe (tools/guest/notify-ready.ps1): %1 the
rem AUMID kaya posts under. Run through schtasks /it like every other guest
rem payload -- the notification platform answers per LOGON SESSION, and an
rem ssh session is session 0.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\notify-ready.ps1 -Aumid "%~1" > C:\kaya\out_notifyready.txt 2>&1

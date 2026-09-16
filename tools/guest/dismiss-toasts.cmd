@echo off
rem Dismiss every kaya toast before an exclusive leg types (tools/guest/dismiss-toasts.ps1):
rem %1 the AUMIDs kaya posts under, '~'-separated. Run through schtasks /it like
rem notify-ready.cmd -- the notification platform answers per LOGON SESSION.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\dismiss-toasts.ps1 -Aumids "%~1" > C:\kaya\out_dismisstoasts.txt 2>&1

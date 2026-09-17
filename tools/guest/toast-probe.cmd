@echo off
rem Raise (or, with -Clear, take down) the flight recorder's toast probe
rem (tools/guest/toast-probe.ps1). Run through schtasks /it and
rem run-hidden-args.vbs like notify-ready.cmd -- the notification platform
rem answers per LOGON SESSION, and a VISIBLE console would itself take the
rem foreground this probe exists to measure.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\toast-probe.ps1 %1 %2 %3 %4 %5 %6 %7 > C:\kaya\out_toastprobe.txt 2>&1

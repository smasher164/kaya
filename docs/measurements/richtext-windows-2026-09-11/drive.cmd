@echo off
rem The rich-text probe's launcher. Scheduled with /it so the probe runs in
rem the interactive session, where its own keybd_event keys reach its own
rem foreground window and where a UIA client can see its windows at all.
cd /d C:\kaya\richtext-probe
del C:\kaya\richtext-probe\log.txt 2>nul
del C:\kaya\richtext-probe\out.txt 2>nul
del C:\kaya\richtext-probe\uia.txt 2>nul
del C:\kaya\richtext-probe\ready.txt 2>nul
del C:\kaya\richtext-probe\uia_done.txt 2>nul
del C:\kaya\richtext-probe\pid.txt 2>nul
start "" /b cmd /c "C:\kaya\richtext-probe\bin\KayaRichProbe.exe > C:\kaya\richtext-probe\out.txt 2>&1"
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\richtext-probe\uia.ps1 > C:\kaya\richtext-probe\uia.txt 2>&1
C:\kaya\richtext-probe\uia3\bin\Release\net10.0-windows\win-arm64\Uia3Probe.exe > C:\kaya\richtext-probe\uia3.txt 2>&1
echo done > C:\kaya\richtext-probe\uia_done.txt

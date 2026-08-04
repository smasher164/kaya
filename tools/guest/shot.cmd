@echo off
rem Photograph the interactive desktop — the two-minute answer when a
rem Windows leg fails in a way that implicates the DESKTOP rather than
rem the app (docs/traps.md: a shell toast holds the foreground).
rem
rem A wrapper rather than a bare schtasks line, for two reasons the
rem plain route got wrong: powershell needs -ExecutionPolicy Bypass to
rem run a shipped .ps1 at all (without it the task exits 1 and leaves
rem YESTERDAY'S shot.png sitting there, which reads as a fresh
rem picture), and this wants running through run-hidden.vbs so the
rem console window does not take the foreground it is here to
rem photograph.
rem
rem   ssh HOST 'schtasks /create /tn kaya_shot /tr "wscript C:\kaya\run-hidden.vbs shot.cmd" /sc once /st 00:00 /it /rl highest /f && schtasks /run /tn kaya_shot'
rem   scp HOST:C:/kaya/shot.png .
del C:\kaya\shot.png 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\shot.ps1
echo SHOTEXIT=%ERRORLEVEL% > C:\kaya\out_shot.txt

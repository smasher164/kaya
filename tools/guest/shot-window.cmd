@echo off
rem Photograph the guest's OWN window (tools/guest/shot-window.ps1), the
rem companion to shot.cmd's whole-desktop grab.
rem
rem A wrapper for shot.cmd's two reasons: powershell needs
rem -ExecutionPolicy Bypass to run a shipped .ps1 at all, and this wants
rem running through run-hidden.vbs so the console window does not take
rem the foreground away from the window being photographed.
rem
rem   ssh HOST 'schtasks /create /tn kaya_winshot /tr "wscript C:\kaya\run-hidden.vbs shot-window.cmd" /sc once /st 00:00 /it /rl highest /f && schtasks /run /tn kaya_winshot'
rem   scp HOST:C:/kaya/shot.png .
del C:\kaya\shot.png 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\shot-window.ps1 > C:\kaya\out_shot_window.txt 2>&1
echo SHOTEXIT=%ERRORLEVEL% >> C:\kaya\out_shot_window.txt

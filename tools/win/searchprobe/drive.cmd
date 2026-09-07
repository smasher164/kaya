@echo off
rem The search probe's launcher (docs/search-plan.md §7). Scheduled with
rem /it so it runs in the interactive session, where its own keybd_event
rem keys reach its own foreground window.
cd /d C:\kaya\searchprobe
del C:\kaya\searchprobe\log.txt 2>nul
del C:\kaya\searchprobe\out.txt 2>nul
C:\kaya\searchprobe\bin\KayaSearchProbe.exe > C:\kaya\searchprobe\out.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\searchprobe\out.txt

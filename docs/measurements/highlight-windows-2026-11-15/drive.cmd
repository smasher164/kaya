@echo off
rem The highlight probe's launcher, scheduled with /it so the window opens in the interactive session.
cd /d C:\kaya\hl-probe
del C:\kaya\hl-probe\log.txt 2>nul
C:\kaya\hl-probe\bin\KayaHlProbe.exe > C:\kaya\hl-probe\out.txt 2>&1

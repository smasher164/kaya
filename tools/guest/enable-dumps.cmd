@echo off
rem Enable WER LocalDumps machine-wide: every user-mode crash writes a
rem full dump to C:\kaya\dumps, so a stowed exception is a postmortem
rem artifact instead of a mystery. Idempotent; run via
rem deploy-win.sh user@host enable-dumps (elevated by schtasks /rl).
mkdir C:\kaya\dumps 2>nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /v DumpFolder /t REG_EXPAND_SZ /d C:\kaya\dumps /f > C:\kaya\out_enable_dumps.txt 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /v DumpType /t REG_DWORD /d 2 /f >> C:\kaya\out_enable_dumps.txt 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /v DumpCount /t REG_DWORD /d 10 /f >> C:\kaya\out_enable_dumps.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_enable_dumps.txt

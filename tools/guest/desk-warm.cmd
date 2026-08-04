@echo off
rem The lane's desktop warm-up, run through run-hidden.vbs under
rem `schtasks /it` so it lands on the SAME interactive desktop the legs
rem land on — and hidden, because a console window of its own would
rem take the foreground it is here to measure.
rem
rem The verdict lives in the file, the way every other guest script
rem reports: deploy-win polls for DESKWARMDONE and reads
rem deskwarm.verdict. See desk-warm.ps1 for what is being proved.
del C:\kaya\out_deskwarm.txt 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\desk-warm.ps1 > C:\kaya\out_deskwarm.txt 2>&1
echo DESKWARMEXIT=%ERRORLEVEL% >> C:\kaya\out_deskwarm.txt

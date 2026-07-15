@echo off
rem One-command postmortem: the latest crash events and any local
rem dumps, in one file — instead of hand-rolled wevtutil queries whose
rem quoting mangles through ssh.
set OUT=C:\kaya\out_crash_report.txt
del %OUT% 2>nul
echo ===EVENT 1000 (application errors, newest first)=== > %OUT%
wevtutil qe Application "/q:*[System[(EventID=1000)]]" /c:5 /rd:true /f:text >> %OUT% 2>&1
echo ===DUMPS=== >> %OUT%
dir /o-d C:\kaya\dumps >> %OUT% 2>&1
echo REPORTDONE >> %OUT%

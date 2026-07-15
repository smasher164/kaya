@echo off
rem Aliveness probe for debugging a crashing suite: start %1.exe with
rem no selftest, wait ~5 seconds, and report whether the process is
rem still running (ALIVE=1) or died during scene construction
rem (ALIVE=0), plus anything it printed. Invoked by deploy-win.sh's
rem probe=<name> mode.
rem
rem This file exists so remote diagnostics are SHIPPED, like every
rem other guest script — never rebuilt on the VM by echoing escaped
rem text over ssh, which mangles reliably (bash quoting x cmd.exe
rem caret escaping); see the deploy-win.sh header.
cd /d C:\kaya
del C:\kaya\out_probe.txt 2>nul
del C:\kaya\out_probe_app.txt 2>nul
start /b C:\kaya\%1.exe > C:\kaya\out_probe_app.txt 2>&1
ping -n 6 127.0.0.1 >nul
tasklist /fi "imagename eq %1.exe" | find /i "%1.exe" >nul
if errorlevel 1 (echo ALIVE=0 > C:\kaya\out_probe.txt) else (echo ALIVE=1 > C:\kaya\out_probe.txt)
taskkill /f /im %1.exe >nul 2>&1
type C:\kaya\out_probe_app.txt >> C:\kaya\out_probe.txt
echo PROBEDONE >> C:\kaya\out_probe.txt

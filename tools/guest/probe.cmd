@echo off
setlocal enabledelayedexpansion
rem Aliveness probe for debugging a crashing suite: start %1.exe (with
rem KAYA_SELFTEST=%2 if given), wait, and report a verdict that cannot
rem be fooled by Windows Error Reporting:
rem
rem   VERDICT=ALIVE    the process is running and WerFault is not
rem                    collecting it
rem   VERDICT=CRASHED  the process is gone
rem
rem TRAP (learned 2026-07-15): tasklist reports a crashing process as
rem running while WerFault has it suspended for dump collection — a
rem plain existence check reads corpses as ALIVE. This probe waits out
rem WerFault before rendering a verdict.
rem
rem Shipped like every guest script — never rebuilt on the VM by
rem echoing escaped text over ssh; see the deploy-win.sh header.
cd /d C:\kaya
del C:\kaya\out_probe.txt 2>nul
del C:\kaya\out_probe_app.txt 2>nul
if not exist C:\kaya\%1.exe (
    echo VERDICT=NO-SUCH-EXE %1.exe > C:\kaya\out_probe.txt
    echo PROBEDONE >> C:\kaya\out_probe.txt
    exit /b 1
)
set KAYA_WINUI_TRACE=1
if not "%2"=="" set KAYA_SELFTEST=%2
start /b C:\kaya\%1.exe > C:\kaya\out_probe_app.txt 2>&1
ping -n 6 127.0.0.1 >nul
rem Wait until WerFault is done collecting (bounded), so a suspended
rem corpse cannot masquerade as a live process.
set WERWAIT=0
:werloop
tasklist /fi "imagename eq WerFault.exe" | find /i "WerFault.exe" >nul
if not errorlevel 1 (
    set /a WERWAIT+=1
    if !WERWAIT! lss 30 (
        ping -n 3 127.0.0.1 >nul
        goto werloop
    )
)
tasklist /fi "imagename eq %1.exe" | find /i "%1.exe" >nul
if errorlevel 1 (
    rem Gone: distinguish a clean selftest exit from a crash.
    findstr /c:"KAYA_SELFTEST: OK" C:\kaya\out_probe_app.txt >nul 2>&1
    if errorlevel 1 (echo VERDICT=CRASHED > C:\kaya\out_probe.txt) else (echo VERDICT=SELFTEST-OK > C:\kaya\out_probe.txt)
) else (
    echo VERDICT=ALIVE > C:\kaya\out_probe.txt
)
taskkill /f /im %1.exe >nul 2>&1
type C:\kaya\out_probe_app.txt >> C:\kaya\out_probe.txt
echo PROBEDONE >> C:\kaya\out_probe.txt

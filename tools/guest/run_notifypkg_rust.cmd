@echo off
cd /d C:\kaya
rem AN INVOKER THAT FAILS SAYS SO IN THE LEG'S OWN FILE: a broken
rem invoker otherwise starts nothing and the runner waits out its whole
rem deadline in silence (measured 2026-09-08, 298s).
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\pkg-run.ps1 -AppId notify -Inner pkg_notifypkg_rust.cmd -Slot "%KAYA_WIN_SLOT%" > C:\kaya\out_notifypkg_rust-invoke.txt 2>&1
if not errorlevel 1 goto :eof
copy /y C:\kaya\out_notifypkg_rust-invoke.txt C:\kaya\out_notifypkg_rust.txt >nul
echo EXIT=1 >> C:\kaya\out_notifypkg_rust.txt

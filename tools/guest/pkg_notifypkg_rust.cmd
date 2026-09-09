@echo off
rem %1 the installed package's location, %2 the tile slot. The caller's
rem environment does not cross Invoke-CommandInDesktopPackage, so every
rem KAYA_ variable this leg needs is set HERE (docs/packaging-plan.md P3).
cd /d C:\kaya
set KAYA_SELFTEST=notify
set KAYA_VERB_TRACE=C:\kaya\flightrec\notifypkg_rust-vtrace.txt
set KAYA_WIN_SLOT=%2
set KAYA_ASSET_DIR=
"%~1\notify.exe" > C:\kaya\out_notifypkg_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_notifypkg_rust.txt

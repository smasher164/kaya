@echo off
cd /d C:\kaya
set KAYA_SELFTEST=grid
grid.exe > C:\kaya\out_grid_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_grid_rust.txt

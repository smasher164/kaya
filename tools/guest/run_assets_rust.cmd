@echo off
cd /d C:\kaya
rem NO ASSET LINE HERE, and on THIS scene that is the whole
rem point: the guest names two assets and reads no path and no
rem environment variable, and the census it freezes is of the
rem root the deploy staged and named machine-wide in
rem KAYA_ASSET_DIR. A per-asset variable in a per-leg launcher
rem is what made every new asset cost five more of these lines.
set KAYA_SELFTEST=assets
assets.exe > C:\kaya\out_assets_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_assets_rust.txt

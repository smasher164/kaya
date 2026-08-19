@echo off
cd /d C:\kaya
rem NO ASSET LINE HERE, and that is the change: `asset(name)`
rem resolves the vendored font in the core, out of the root the
rem deploy stages and names machine-wide in KAYA_ASSET_DIR. A
rem per-asset variable in a per-leg launcher is what made every
rem new asset cost five more of these lines.
set KAYA_SELFTEST=typeface
typeface.exe > C:\kaya\out_typeface_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_rust.txt

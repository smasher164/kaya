@echo off
cd /d C:\kaya
rem NO ASSET LINE HERE ANY MORE: the guest names the mark
rem `asset("icons/kaya-mark.png")` and the core resolves it out
rem of the root the deploy stages and names machine-wide in
rem KAYA_ASSET_DIR — the typeface scene's rule, one asset over.
set KAYA_SELFTEST=identity
identity.exe > C:\kaya\out_identity_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_rust.txt

@echo off
cd /d C:\kaya
rem The vendored mark's bytes are what the guest declares; named
rem absolutely so no leg depends on its cwd (deploy-win.sh ships it to
rem the repo-mirror path, the vendored font's rule one asset over).
set KAYA_ICON_FILE=C:\kaya\guests\assets\icons\kaya-mark.png
set KAYA_SELFTEST=identity
identity.exe > C:\kaya\out_identity_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_identity_rust.txt

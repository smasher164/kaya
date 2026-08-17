@echo off
cd /d C:\kaya
rem The vendored font's bytes are what the guest hands the backend;
rem named absolutely so no leg depends on its cwd (deploy-win.sh ships
rem it to the repo-mirror path).
set KAYA_FONT_FILE=C:\kaya\guests\assets\fonts\sora-wght.ttf
set KAYA_SELFTEST=typeface
typeface.exe > C:\kaya\out_typeface_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_rust.txt

@echo off
cd /d C:\kaya
set KAYA_SELFTEST=gallery
gallery.exe > C:\kaya\out_gallery_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_gallery_rust.txt

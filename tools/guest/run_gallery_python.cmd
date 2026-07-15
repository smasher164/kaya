@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
set KAYA_SELFTEST=gallery
python C:\kaya\gallery.py > C:\kaya\out_gallery_python.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_gallery_python.txt

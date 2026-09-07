@echo off
cd /d C:\kaya
set KAYA_SELFTEST=gallery
set KAYA_VERB_TRACE=C:\kaya\flightrec\gallery_rust-vtrace.txt
gallery.exe > C:\kaya\out_gallery_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_gallery_rust.txt

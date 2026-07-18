@echo off
cd /d C:\kaya
set KAYA_SELFTEST=feed
feed.exe > C:\kaya\out_feed_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_feed_rust.txt

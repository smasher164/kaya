@echo off
cd /d C:\kaya
set KAYA_SELFTEST=feed
set KAYA_VERB_TRACE=C:\kaya\flightrec\feed_rust-vtrace.txt
feed.exe > C:\kaya\out_feed_rust.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_feed_rust.txt

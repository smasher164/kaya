@echo off
cd /d C:\kaya
set KAYA_SCENES_DIR=C:\kaya\nfprobe
set KAYA_SELFTEST=nfprobe
if not "%2"=="-" set KAYA_LOCALE=%2
if "%3"=="stock" set KAYA_PROBE_STOCK_NUMBERBOX=1
rmdir /s /q C:\kaya\legs\nfprobe 2>nul
mkdir C:\kaya\legs\nfprobe\state 2>nul
set XDG_STATE_HOME=C:\kaya\legs\nfprobe\state
del C:\kaya\nfprobe\%1-vtrace.txt 2>nul
set KAYA_VERB_TRACE=C:\kaya\nfprobe\%1-vtrace.txt
powershell -NoProfile -Command "'culture=' + (Get-Culture).Name + ' sDecimal=' + (Get-ItemProperty 'HKCU:\Control Panel\International').sDecimal + ' sThousand=' + (Get-ItemProperty 'HKCU:\Control Panel\International').sThousand" > C:\kaya\nfprobe\%1-out.txt 2>&1
C:\kaya\nfprobe.exe >> C:\kaya\nfprobe\%1-out.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\nfprobe\%1-out.txt

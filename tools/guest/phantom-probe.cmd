@echo off
rem Watch the console session's foreground and read the notification host
rem window when it holds it (tools/guest/phantom-probe.ps1). Run through
rem schtasks /it and run-hidden-args.vbs like toast-probe.cmd -- a VISIBLE
rem console would itself take the foreground this probe exists to measure.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\phantom-probe.ps1 %* > C:\kaya\out_phantomprobe.txt 2>&1

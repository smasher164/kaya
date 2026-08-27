@echo off
rem The flight recorder's guest entry point: flightrec.cmd <mode> <leg>.
rem
rem -ExecutionPolicy Bypass is not optional for a shipped .ps1 — without it
rem the task exits 1 and leaves the PREVIOUS run's file in place, which
rem then reads as a fresh capture (the trap tools/guest/shot.cmd records).
rem
rem Launched through run-hidden-args.vbs so no console window appears: the
rem sample mode is measuring which window holds the foreground, and its own
rem console would be the answer.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\kaya\flightrec.ps1 -Mode %1 -Leg %2

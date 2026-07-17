@echo off
rem Recording mode: run the WGC capturer (built on this VM from
rem C:\kaya\record-win) until the stop file appears. GDI-family
rem capture shows WinUI's DirectComposition content as blank; the
rem Windows.Graphics.Capture tool reads the compositor itself and is
rem window-scoped, so nothing else on the desktop enters the film.
del C:\kaya\out_record.txt 2>nul
echo RECORDING_TASK_STARTED > C:\kaya\out_record.txt
C:\kaya\record-win\bin\Release\net10.0-windows10.0.22621.0\record-win.exe C:\kaya\frames >> C:\kaya\out_record.txt 2>&1
echo RECORDING_TASK_DONE %ERRORLEVEL% >> C:\kaya\out_record.txt

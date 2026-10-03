@echo off
rem The capture legs' synthetic devices (tools/winvcam, docs/HACKING.md's
rem capture install): the two virtual cameras and the cable's tone, started
rem by tools/deploy-win.py through schtasks /it before the capture legs and
rem stopped after by the stop file. A virtual camera belongs to the logon
rem session that made it, so never over ssh. %1 the wall-clock bound in seconds.
C:\kaya\kaya-capture-lane.exe run C:\kaya\capture-lane.ready C:\kaya\capture-lane.stop %1 > C:\kaya\capture-lane.log 2>&1

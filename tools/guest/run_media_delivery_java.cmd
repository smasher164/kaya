@echo off
cd /d C:\kaya
set PATH=C:\kaya;%PATH%
rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): the harness's
rem scratch -- the act-two marker, the preferences domain and the app's
rem data directory -- is ONE tree per app, and this lane runs many legs
rem of one app at once, so every act one EMPTIES that tree and a pooled
rem neighbour's open SQLite goes readonly under it. Cleared HERE, at the
rem leg's own start, and nowhere else: the second act must KEEP it.
rmdir /s /q C:\kaya\legs\media_delivery_java 2>nul
mkdir C:\kaya\legs\media_delivery_java\state 2>nul
rem The media suite's server, the runner's own (tools/lib/lanes/win.py MEDIA_HOST,
rem tools/lib/media_server.py LANE_PORTS).
set KAYA_MEDIA_URL=http://192.168.64.1:8768
set XDG_STATE_HOME=C:\kaya\legs\media_delivery_java\state
set KAYA_SELFTEST=media_delivery
set KAYA_VERB_TRACE=C:\kaya\flightrec\media_delivery_java-vtrace.txt
java -cp C:\kaya\java\classes dev.kaya.guests.Main > C:\kaya\out_media_delivery_java.txt 2>&1
echo EXIT=%ERRORLEVEL% >> C:\kaya\out_media_delivery_java.txt

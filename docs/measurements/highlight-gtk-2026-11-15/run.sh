#!/usr/bin/env bash
# Runs inside the kaya-linux image: Xvfb, a session bus, the a11y bus, the app, the reader.
set -u
Xvfb :79 -screen 0 1600x1000x24 >/dev/null 2>&1 &
export DISPLAY=:79 GDK_BACKEND=x11
eval "$(dbus-launch --sh-syntax)"
/usr/libexec/at-spi-bus-launcher --launch-immediately >/dev/null 2>&1 &
sleep 1
/usr/libexec/at-spi2-registryd >/dev/null 2>&1 &
export GTK_A11Y=atspi NO_AT_BRIDGE=0
sleep 1
python3 /probe/app.py > /out/app.log 2>&1 &
app=$!
for _ in $(seq 1 40); do grep -q DONE /out/pixels.txt 2>/dev/null && break; sleep 0.5; done
python3 /probe/reader.py > /out/reader.log 2>&1
reader_rc=$?
echo "reader rc=$reader_rc"
wait "$app"
pkg-config --modversion gtk4

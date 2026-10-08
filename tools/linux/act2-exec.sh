#!/usr/bin/env bash
# The desktop entry's Exec on a notify leg (docs/tasks-s9-plan.md R6).
#
#     act2-exec.sh <the leg's launcher> [args...]
#
# THE LEG'S OWN LAUNCHER, with the relaunched process's output KEPT. A
# D-Bus-activated process's stdio belongs to the bus daemon, and
# dbus-launch detaches the daemon's — so act two's own lines (its verdict,
# its KAYA_DIAG sentences, a panic) reach nobody, and only the verdict FILE
# survives. This appends them to $KAYA_ACT2_LOG, which
# tools/linux/notify-leg.sh prints beside the daemon's record.
#
# A LAUNCHER SHAPE, so it stays shell (CLAUDE.md's python-first boundary):
# its whole body is a redirect and a wait, and its caller is a .desktop
# Exec line.
# NOT `exec`: the start line and the exit status are what tell a door
# that ran nothing from a process that died (tools/linux/door_record.py).
kaya_log="${KAYA_ACT2_LOG:-/dev/null}"
echo "act2-exec: pid $$ started at $(date +%s.%N): $*" >>"$kaya_log"
"$@" >>"$kaya_log" 2>&1
kaya_rc=$?
echo "act2-exec: pid $$ exited $kaya_rc at $(date +%s.%N)" >>"$kaya_log"
exit "$kaya_rc"

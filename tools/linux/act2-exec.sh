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
# its whole body is a redirect and an exec, and its caller is a .desktop
# Exec line.
exec "$@" >>"${KAYA_ACT2_LOG:-/dev/null}" 2>&1

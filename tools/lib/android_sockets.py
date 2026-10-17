"""Android 15's deferred socket destruction, read off `dumpsys connectivity`
(docs/traps.md, "The sockets a stale freeze destroyed")."""

import re

PENDING = re.compile(r"mDestroySocketPendingUids:([^\n]*)")
ENTRY = re.compile(r"(\d+): reasons=([0-3])")
REASONS = {1: "frozen", 2: "background firewall"}


def pending(dumpsys):
    """{uid: reasons} for every uid whose live TCP sockets the platform will
    destroy the next time the cell radio wakes, or None when the dump has no
    DestroySockets section. The dump runs its entries together with no
    separator (`10140: reasons=110208: reasons=1`); a reason is two bits."""
    m = PENDING.search(dumpsys)
    if m is None:
        return None
    return {int(uid): int(r) for uid, r in ENTRY.findall(m.group(1))}


def named(reasons):
    return "+".join(name for bit, name in REASONS.items() if reasons & bit) or "none"


# Real `dumpsys connectivity` lines from the pool's phones (2026-10-17).
CASES = [
    ("  mDestroySocketPendingUids:\nBpf Program Status:\n", {}),
    ("  mDestroySocketPendingUids:10140: reasons=1\n", {10140: 1}),
    ("  mDestroySocketPendingUids:10140: reasons=110208: reasons=1\n",
     {10140: 1, 10208: 1}),
    ("  mDestroySocketPendingUids:10208: reasons=320208: reasons=2\n",
     {10208: 3, 20208: 2}),
    ("DestroySockets:\n  mDestroyFrozenSockets=false\nBpf Program Status:\n", None),
]


def self_test(read=pending):
    """The findings, one per case `read` answers wrongly."""
    bad = []
    for text, want in CASES:
        got = read(text)
        if got != want:
            bad.append(f"android_sockets: {text.strip()!r} read as {got}, wanted {want}")
    return bad

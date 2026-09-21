"""The host libkaya's on-disk identity, for the two runners that must know
whether it moved under them (docs/traps.md, the sweep-relinked-libkaya entry).
Not in kaya_gate: every keyed gate imports the prelude, and check-keyed holds
each keyed gate to declaring every artifact path its imports name."""
import os
import pathlib

from kaya_gate import ROOT

HOST_LIB = ("target/debug/libkaya.dylib", "target/debug/deps/libkaya.dylib")


def host_lib_stamp(root=None):
    """The host libkaya's on-disk identity. Every mac guest and probe loads
    it by path and any host build of the lib relinks it (docs/traps.md,
    the sweep-relinked-libkaya entry)."""
    base = pathlib.Path(root) if root is not None else ROOT
    out = []
    for rel in HOST_LIB:
        try:
            st = os.stat(base / rel)
            out.append((rel, st.st_ino, st.st_mtime_ns, st.st_size))
        except FileNotFoundError:
            out.append((rel, None))
    return tuple(out)

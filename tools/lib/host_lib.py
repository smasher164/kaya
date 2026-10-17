"""The host libkaya's on-disk identity, for the two runners that must know
whether it moved under them (docs/traps.md, the sweep-relinked-libkaya entry).
Not in kaya_gate: every keyed gate imports the prelude, and check-keyed holds
each keyed gate to declaring every artifact path its imports name."""
import os
import pathlib

from kaya_gate import ROOT

HOST_LIB = ("target/debug/libkaya.dylib", "target/debug/deps/libkaya.dylib")

# validate-all's gate sweep builds here and nowhere else, so no build of its
# can relink the HOST_LIB the mac lane's guests load (docs/traps.md, the
# sweep-relinked-libkaya entry; tools/check-gates.py holds the launch).
SWEEP_TARGET = ROOT / "target/gate-sweep"


def host_lib_stamp(root=None, target=None):
    """The host libkaya's on-disk identity. Every mac guest and probe loads
    it by path and any host build of the lib relinks it (docs/traps.md,
    the sweep-relinked-libkaya entry). `target` reads the same two files
    under another cargo target directory."""
    base = pathlib.Path(root) if root is not None else ROOT
    out = []
    for rel in HOST_LIB:
        p = (pathlib.Path(target) / rel.removeprefix("target/")
             if target is not None else base / rel)
        try:
            st = os.stat(p)
            out.append((rel, st.st_ino, st.st_mtime_ns, st.st_size))
        except FileNotFoundError:
            out.append((rel, None))
    return tuple(out)

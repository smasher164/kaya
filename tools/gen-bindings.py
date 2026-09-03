#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Regenerate bindings/<lang> from kaya::spec (kaya-bindgen) — the one
# spelling of the invocation.
#
# Usage: tools/gen-bindings.py [--check]   (--check fails on stale or
# ungeneratable bindings and touches nothing)

import hashlib
import os
import subprocess


def kaya_generator_id():
    """The generator's source, hashed: content-only, not mtime
    (docs/traps.md). check-steps' generator_stamp recomputes this —
    the two must agree byte for byte."""
    h = hashlib.sha256()
    for p in sorted((ROOT / "tools/kaya-bindgen/src").glob("*.rs")):
        h.update(p.read_bytes())
    return h.hexdigest()[:16]


# KAYA_REGENERATING exempts this one build from the staleness refusal in
# crates/kaya/build.rs: the generator depends on the kaya crate, so
# without it a generator edit deadlocks against its own staleness.
# --locked: the shell body ran a bare `cargo run` for its whole life —
# `run` resolves dependencies exactly as `build` does, and it was the
# one cargo invocation outside the (build|check|test) alternation both
# cargo rules police (audit follow-up 2026-08-31; the rules now name
# `run` too).
r = subprocess.run(
    ["cargo", "run", "--locked", "--quiet", "--", str(ROOT),
     *sys.argv[1:]],
    cwd=ROOT / "tools/kaya-bindgen",
    env=dict(os.environ, KAYA_REGENERATING="1"), check=False)
if r.returncode != 0:
    sys.exit(r.returncode)

# The generator's own fingerprint, stamped beside what it produced, so a
# cheap gate can ask "was this regenerated?" in milliseconds
# (docs/traps.md). Written only on a real generation — --check must not
# move it, or the stamp certifies the staleness it exists to catch.
if sys.argv[1:2] != ["--check"]:
    (ROOT / "bindings/.generator-id").write_text(
        kaya_generator_id() + "\n", encoding="utf-8")

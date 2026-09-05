#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# Compile-check the one Go module — the binding, every Go guest and the
# generator — the way java-typecheck and js-typecheck do their languages.
# Nothing in the sweep did this before 2026-09-04, when a scene row
# duplicated in guests/go/cmd/scenes.go compiled in no gate, and every
# lane's guest build died on it: five lanes, zero legs on three of them,
# one matrix spent to learn what `go vet` says in seconds (docs/traps.md).

import shutil
import subprocess

sys.stdout.reconfigure(line_buffering=True)

g = Gate("go-typecheck")


def go(*args, cwd=ROOT):
    return subprocess.run(["go", *args], cwd=cwd, capture_output=True, text=True, check=False)


# The three Go trees the lanes build; docs/probes and tools/checks hold C
# probes with a .go beside them and are no part of the module's build.
TREES = ["./bindings/go/...", "./guests/go/...", "./cmd/..."]
listed = go("list", *TREES)
if listed.returncode != 0:
    g.finding(f"go list failed:\n{listed.stderr.strip()}")
packages = [p for p in listed.stdout.split() if p]
g.counted("Go packages listed", len(packages), floor=40)

# vet's unsafeptr analyzer flags bindings/go/runtime.go's uintptr->Pointer
# reads of the ring: that memory is libkaya's, not the Go heap, which the
# analyzer cannot see. Everything else vet checks stays on.
VET = ["vet", "-unsafeptr=false"]
vet = go(*VET, *TREES)
if vet.returncode != 0:
    g.finding(f"go vet failed:\n{vet.stderr.strip()[:4000]}")
else:
    print(f"go-typecheck: go vet clean over {len(packages)} packages")

# THE NEGATIVE, on a COPY of the module (perturb-restore never touches the
# tree): the shipped defect itself — a scene row declared twice — must be
# refused by the same command. The copy carries every .go file, the
# module files and the C header cgo preprocesses; nothing is linked.
scratch = g.scratch() / "module"
tracked = subprocess.run(["git", "ls-files", "*.go", "go.mod", "go.sum", "crates/kaya/include"],
                         cwd=ROOT, capture_output=True, text=True, check=False).stdout.split()
for rel in tracked:
    dst = scratch / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / rel, dst)
g.counted("files copied for the negative", len(tracked), floor=60)
table = scratch / "guests/go/cmd/scenes.go"
doctored = g.doctor("a scene row declared twice", table.read_text(encoding="utf-8"),
                    r'\t"gallery":\s+gallery\.App,\n',
                    '\t"gallery":    gallery.App,\n\t"gallery":    gallery.App,\n')
table.write_text(doctored, encoding="utf-8")
bad = go(*VET, "./guests/go/cmd/", cwd=scratch)
if bad.returncode == 0 or "duplicate key" not in bad.stderr:
    g.finding("the negative did not fire: a duplicated scene row was not refused by go vet "
              f"(rc {bad.returncode}): {bad.stderr.strip()[:400]}")
else:
    print("go-typecheck: watched refusing: a scene row declared twice (duplicate key)")

g.verdict(f"the Go module compiles: {len(packages)} packages")

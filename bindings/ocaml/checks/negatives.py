#!/usr/bin/env python3
"""F1/F3/F4 negatives: bindings/ocaml/checks/negatives/*.ml must each
FAIL to compile against kaya_guest_binding, and fail on the ONE line
the finding is about. Run after `dune build` has produced the
library's .cmi files (tools/run-leg.py / the mac lane's ocaml build).
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CMI_DIR = ROOT / "_build/default/bindings/ocaml/.kaya_guest_binding.objs/byte"
NEG_DIR = Path(__file__).resolve().parent / "negatives"
ISOLATION = ROOT / "_build/default/bindings/ocaml/checks/guest_isolation.exe"
GUESTS = ROOT / "guests/ocaml"

CASES = {
    "signal_type_mismatch.ml": ["has type bool", "expected of type", "string"],
    "role_bad_type.ml": ["Kaya_app.Menu_role.t"],
    "key_bad_type.ml": ["Kaya_app.key"],
    # The correction slice (the idiom review, 2026-09-17).
    "alert_choice_bad_type.ml": ["Alert_choice.t"],
    "file_mode_bad_type.ml": ["File_mode.t"],
    "derive_witness.ml": ["Scalar.t"],
    "engine_reach.ml": ["widget_handlers"],
    "run_span.ml": ["start"],
    # X3 (the body-value ruling, 2026-09-17).
    "when_body_value.ml": ["widget * "],
}


def main():
    if not CMI_DIR.exists():
        print(f"negatives: {CMI_DIR} missing — build bindings/ocaml/ first "
              "(dune build --root .)")
        return 1
    red = 0
    for name, want_substrings in CASES.items():
        src = NEG_DIR / name
        proc = subprocess.run(
            ["ocamlfind", "ocamlc", "-package",
             "ctypes,ctypes-foreign,threads.posix",
             "-I", str(CMI_DIR), "-c", str(src)],
            cwd=NEG_DIR, capture_output=True, text=True, check=False)
        if proc.returncode == 0:
            print(f"negatives: {name} COMPILED — the refusal it names is gone")
            return 1
        missing = [s for s in want_substrings if s not in proc.stderr]
        if missing:
            print(f"negatives: {name} failed, but not on its own refusal "
                  f"(missing {missing!r} in stderr):\n{proc.stderr}")
            return 1
        print(f"negatives: {name} refused as wanted")
        red += 1
    if red != len(CASES):
        print(f"negatives: {red}/{len(CASES)} refused — census floor")
        return 1
    print(f"ocaml negatives: OK ({red} refused)")
    return isolation_negatives()


def isolation_negatives():
    """guests/ocaml/dune's link_deps wall (docs/traps.md, an OCaml guest
    naming a sibling guest's module runs that guest)."""
    if not ISOLATION.exists():
        print(f"negatives: {ISOLATION} missing — build first (dune build --root .)")
        return 1
    ocamldep = shutil.which("ocamldep")
    if ocamldep is None:
        print("negatives: ocamldep is not on PATH — run inside the dev shell")
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp)
        for src in GUESTS.glob("*.ml"):
            shutil.copy(src, scratch / src.name)
        media = scratch / "media.ml"
        text = media.read_text(encoding="utf-8")
        n = text.count("t.Kaya_app.Tracks.audio")
        print(f"negatives: guest isolation: {n} substitution(s) of the shipped "
              "t.Tracks.audio back into media.ml")
        if n != 1:
            print("negatives: guest isolation: the perturbation applied nothing")
            return 1
        media.write_text(text.replace("t.Kaya_app.Tracks.audio", "t.Tracks.audio"),
                         encoding="utf-8")
        files = sorted(str(p) for p in scratch.glob("*.ml"))
        cases = {
            "the shipped media.ml -> tracks.ml link": (
                files, "media.ml names the module Tracks, which is also the guest tracks.ml"),
            "a deps list under the floor": (
                files[:3], "under its floor of 40"),
        }
        for what, (argv, want) in cases.items():
            proc = subprocess.run([str(ISOLATION), ocamldep, *argv], capture_output=True,
                                  text=True, encoding="utf-8", check=False)
            if proc.returncode == 0 or want not in proc.stderr:
                print(f"negatives: guest isolation passed {what} (exit {proc.returncode}):\n"
                      f"{proc.stdout}{proc.stderr}")
                return 1
            print(f"negatives: guest isolation refused {what}")
    print("guest isolation negatives: OK (2 refused)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""F1/F3/F4 negatives: bindings/ocaml/checks/negatives/*.ml must each
FAIL to compile against kaya_guest_binding, and fail on the ONE line
the finding is about. Run after `dune build` has produced the
library's .cmi files (tools/run-leg.py / the mac lane's ocaml build).
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CMI_DIR = ROOT / "_build/default/bindings/ocaml/.kaya_guest_binding.objs/byte"
NEG_DIR = Path(__file__).resolve().parent / "negatives"

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
    return 0


if __name__ == "__main__":
    sys.exit(main())

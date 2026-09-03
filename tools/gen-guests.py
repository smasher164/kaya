#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# Regenerate the per-language guest surfaces from the guests' own
# KayaGen-marked declarations (DESIGN.md's eliminator-convergence note).
# --check snapshots the tree AS IT STOOD, regenerates in place, diffs,
# puts every byte back on every exit path, and REFUSES A VERDICT if the
# restore left the tree changed. Diffing against GIT instead silently
# reverts any hand-edit to a generated file and calls the tree clean
# (docs/traps.md).

import hashlib
import os
import shutil
import subprocess

os.chdir(ROOT)

GENERATED = ["guests/*_kaya.go", "guests/*Kaya.java", "guests/*Kaya.cs",
             "guests/*+Kaya.swift"]
CHECK = sys.argv[1:2] == ["--check"]


def git_lines(*args):
    r = subprocess.run(["git", *args], stdout=subprocess.PIPE,
                       text=True, encoding="utf-8", check=False)
    if r.returncode != 0:
        print(f"gen-guests: git {' '.join(args[:2])} failed "
              f"(exit {r.returncode}) — no verdict without the "
              f"generated-surface census", file=sys.stderr)
        sys.exit(1)
    return [ln for ln in r.stdout.split("\n") if ln]


def list_generated():
    return sorted(set(git_lines("ls-files", "--", *GENERATED)
                      + git_lines("ls-files", "--others",
                                  "--exclude-standard", "--",
                                  *GENERATED)))


def sha_over(files):
    text = ""
    for f in files:
        p = pathlib.Path(f)
        if p.exists():
            text += f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {f}\n"
        else:
            text += f"MISSING {f}\n"
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def run_javac(*args):
    try:
        ok = subprocess.run(["javac", "-version"],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            check=False).returncode == 0
    except FileNotFoundError:
        ok = False
    cmd = ["javac"] if ok else ["nix", "shell", "nixpkgs#jdk17", "-c",
                                "javac"]
    return subprocess.run([*cmd, *[str(a) for a in args]],
                          check=False).returncode


def generate(tmp):
    """The four generators, in the shell body's order; first failure
    wins. Returns 0 or the `exit 1` the shell spelled per generator."""
    # Go: every //go:generate directive under guests/go runs
    # cmd/kaya-gen.
    if subprocess.run(["go", "generate", "./guests/go/..."],
                      check=False).returncode != 0:
        return 1

    # Java: the annotation processor over the APK guest sources.
    # -proc:only parses and generates without compiling; the generated
    # *Kaya.java are excluded from the run's inputs and rewritten.
    if run_javac("-encoding", "UTF-8", "-d", tmp / "japt",
                 "bindings/java/dev/kaya/KayaGen.java",
                 "tools/java-processor/dev/kaya/processor/"
                 "KayaProcessor.java") != 0:
        return 1
    java_guests = sorted(
        str(p) for p in pathlib.Path("guests/java").rglob("*.java")
        if not p.name.endswith("Kaya.java"))
    if run_javac("-encoding", "UTF-8", "-proc:only",
                 "-processorpath", tmp / "japt",
                 "-processor", "dev.kaya.processor.KayaProcessor",
                 "-Akaya.out=guests/java",
                 "bindings/java-desktop/dev/kaya/KayaRing.java",
                 "bindings/java/dev/kaya/KayaApp.java",
                 "bindings/java/dev/kaya/KayaRecords.java",
                 "bindings/java/dev/kaya/KayaSums.java",
                 "bindings/java/dev/kaya/KayaWire.java",
                 "bindings/java/dev/kaya/KayaGen.java",
                 *java_guests) != 0:
        return 1

    # C#: the Roslyn CLI over the guest sources (the tool's NuGet
    # dependency stays the tool's — guests remain dependency-free).
    if subprocess.run(["dotnet", "run", "--project", "tools/kaya-csgen",
                       "--", "guests/csharp"],
                      check=False).returncode != 0:
        return 1

    # Swift: the swift-syntax CLI over each guest file that declares
    # sums. SPM runs outside the nix DEVELOPER_DIR — nix's apple-sdk
    # has no SPM on darwin. --disable-automatic-resolution is SwiftPM's
    # --locked: the swift-syntax dependency is a RANGE and only the
    # checked-in Package.resolved makes it a version.
    env = {k: v for k, v in os.environ.items()
           if k not in ("DEVELOPER_DIR", "SDKROOT")}
    if subprocess.run(["swift", "run", "--disable-automatic-resolution",
                       "--package-path", "tools/kaya-swift-gen",
                       "kaya-swift-gen", "guests/swift/feed.swift",
                       "guests/swift/todos.swift",
                       "guests/swift/reorder.swift",
                       "guests/swift/undo.swift",
                       "guests/swift/table.swift"],
                      env=env, check=False).returncode != 0:
        return 1
    return 0


def check_mode(tmp):
    # Snapshot, regenerate, diff against the snapshot, put every byte
    # back, refuse a verdict if the restore left the tree changed.
    all_files = list_generated()
    before, missing = [], []
    saved = tmp / "saved"
    for f in all_files:
        p = pathlib.Path(f)
        if p.exists():
            dst = saved / f
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, dst)
            # The pre-check mtime, kept so an in-place rewrite of
            # IDENTICAL bytes can be undone below: a fresh mtime makes
            # cargo relink libkaya on every sweep, and every relink mints
            # a new LC_UUID (measured 2026-08-20 — the artifact gate keys
            # never hit).
            (saved / f"{f}.mtime").write_text(
                str(p.stat().st_mtime_ns), encoding="utf-8")
            before.append(f)
        else:
            # Tracked as a generated surface, absent from the tree —
            # its own red below, and the restore keeps it absent.
            missing.append(f)
    before_sha = sha_over(all_files)

    gen_rc = generate(tmp)

    red = 0
    for f in list_generated():
        if f not in all_files:
            print(f"gen-guests: generators produce {f}, which the tree "
                  f"does not carry — run tools/gen-guests.py and commit",
                  file=sys.stderr)
            pathlib.Path(f).unlink(missing_ok=True)
            red = 1
    for f in missing:
        print(f"gen-guests: {f} is tracked as a generated surface but "
              f"missing from the tree — run tools/gen-guests.py and "
              f"commit", file=sys.stderr)
        pathlib.Path(f).unlink(missing_ok=True)
        red = 1
    for f in before:
        p = pathlib.Path(f)
        if not p.exists() or p.read_bytes() != (saved / f).read_bytes():
            print(f"gen-guests: {f} is stale against its generator — "
                  f"run tools/gen-guests.py and commit", file=sys.stderr)
            shutil.copy2(saved / f, p)
            red = 1
    after_sha = sha_over(all_files)
    if after_sha != before_sha:
        print("gen-guests: REFUSING A VERDICT — --check modified the "
              "tree it was checking", file=sys.stderr)
        sys.exit(2)
    # Bytes are proven identical (the sha above); give every file its
    # pre-check mtime back so the regeneration is invisible to cargo —
    # see the snapshot comment for the relink churn this stops.
    for f in before:
        m = saved / f"{f}.mtime"
        if m.is_file():
            ns = int(m.read_text(encoding="utf-8"))
            os.utime(f, ns=(ns, ns))
    if gen_rc != 0:
        # The restore above ran regardless; the generator's failure still
        # wins.
        sys.exit(gen_rc)
    # Drift's sibling, omission: a generated file the tree carries but
    # git does not.
    untracked = git_lines("ls-files", "--others", "--exclude-standard",
                          "--", *GENERATED)
    if untracked:
        print("gen-guests: generated surfaces are not checked in:",
              file=sys.stderr)
        print("\n".join(untracked), file=sys.stderr)
        red = 1
    if red:
        sys.exit(1)


with scratch_dir("gen-guests-") as tmp:
    if CHECK:
        check_mode(tmp)
    else:
        rc = generate(tmp)
        if rc != 0:
            sys.exit(rc)
print("gen-guests: OK")

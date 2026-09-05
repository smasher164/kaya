#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT

# A hash over an artifact's INPUT sources, and `--verify` to ask a built
# file which sources it came from (docs/traps.md: "A failed build must not
# leave a usable artifact", "An unchecked interpreter build degrades to
# yesterday's dylib").
#
# NO dev_shell_or_die, deliberately: this runs on the host, inside the
# Linux container, and out of build.rs during cross-compiles.

import hashlib
import os
import subprocess
import zipfile

root = ROOT

# What each artifact is BUILT FROM. Cargo.lock is an input, not an
# output: the resolved dependency graph is compiled into the library.
COMPONENTS = {
    "core": ["crates", "Cargo.toml", "Cargo.lock"],
    # The INTERFACE it compiles against (kaya.h), not the core's
    # implementation — a gtk.rs edit does not change this dylib.
    "swiftui": ["swift", "crates/kaya/include"],
    # android/kaya/src holds only sources (gradle's outputs are in
    # android/*/build, a SIBLING of src), so the marker this id feeds
    # cannot land inside its own inputs.
    "compose": ["android/kaya/src", "bindings/java"],
}

# What each GATE reads BEYOND the implicit set every one of them gets:
# tools/ plus flake.nix/flake.lock — see gate_key. Read by
# tools/keyed.py.
#
# THE RULE FOR EDITING THIS TABLE: sets are deliberately
# OVER-approximate, whole directories rather than file lists. Naming too
# much costs a re-run nobody notices; naming too little hands back a
# PASS about code that changed since.
#
# check-build-id stays absent forever: its whole job is catching a stale
# artifact, and any cache of that answer is the defect it exists to find.
GATES = {
    "gen-header": ["crates", "Cargo.toml", "Cargo.lock"],
    "gen-bindings": ["crates", "bindings"],
    "gen-guests": ["crates", "bindings", "guests"],
    # The backends: check-steps stops demanding a runner's legs where that
    # backend declares a depth stub, so REMOVING one must fail.
    "check-steps": ["guests", "crates", "swift", "android", "bindings"],
    "check-shell": [],
    # Everything it reads is under tools/, which rides every key (gate_key).
    "check-python": [],
    "check-mirror": ["CLAUDE.md", "AGENTS.md"],
    # AGENTS.md is declared unread, per the over-approximate rule.
    "check-gates": ["CLAUDE.md", "AGENTS.md"],
    "check-ledger": ["docs"],
    # bindings/ and go.mod: the go-android clause cross-builds a fixture
    # against bindings/go through a filesystem replace.
    "check-targets": ["crates", "Cargo.toml", "Cargo.lock", ".cargo",
                      "bindings", "go.mod"],
    # guests/: the SCENE-TIER clause reads guests/*/entry.*. docs/ here and
    # below: keyed-inputs cannot tell a cited path from a read one.
    "check-sugar-surface": ["crates", "bindings", "guests", "docs"],
    "check-universal-props": ["crates", "bindings", "swift", "android"],
    # No binding sits between an authored role and the backends; same for
    # check-native-undo.
    "check-roles": ["crates", "swift", "android"],
    "check-native-undo": ["crates", "swift", "android"],
    # The slider commit rule is a lowering: no binding stands between the
    # occurrence and the four arms.
    "check-slider-commit": ["crates", "android"],
    # No binding: the card is a lowering. swift/ is an input because the
    # iOS synthesized tier draws it and the mac clause reads that file.
    "check-table-card": ["crates", "swift", "android"],
    # Every root the census walks: it finds a why-not by name alone, so a
    # key blind to one root passes stale for the file that just grew one.
    "check-diagnostics": ["crates", "swift", "android", "bindings",
                          "guests", "cmd"],
    "check-verbs": ["crates", "bindings", "swift", "android"],
    # tools/checks/ too: its clause B compiles the probe that lives there.
    "check-harness-ceiling": ["crates", "swift", "android", "tools/checks"],
    "check-file-modes": ["crates", "bindings", "swift", "android"],
    "check-go-env": ["bindings", "guests"],
    "check-jni": ["crates", "android/kaya/src", "bindings/java-desktop"],
    # docs/: a stub is sanctioned only while its ledger entry is unstruck.
    "check-stubs": ["crates", "swift", "android", "docs"],
    "check-staging": ["guests"],
    # Its walk is guests/**/*.c, not guests/c alone; a key narrower than
    # the walk passes stale for a C guest in a new directory.
    "check-c-ids": ["guests"],
    # bindings/ for the generated header it reads, tools/checks/ for the
    # probe it compiles, guests/ for the Makefile flag clause.
    "check-c-bounds": ["bindings", "guests", "tools/checks"],
    # gradle's :kaya sourceSet reaches nothing else outside android/.
    "check-compose": ["android", "bindings/java"],
    "check-detekt": ["android"],
    "check-compose-state": ["android", "docs"],
    "check-pins": ["android"],
    # The INTERFACE, not the implementation: kaya.h's own freshness is
    # gated by gen-header, which is keyed on all of crates/.
    "swift-typecheck": ["crates/kaya/include", "bindings/swift",
                        "guests/swift", "swift"],
    "java-typecheck": ["bindings/java", "bindings/java-desktop", "guests/java"],
    "js-typecheck": ["bindings/js", "guests/js"],
    "go-typecheck": ["go.mod", "go.sum", "bindings/go", "guests/go", "cmd", "crates/kaya/include"],
    # The five ARTIFACT gates: sources here, the built file below.
    "check-abort": ["crates", "bindings", "guests"],
    "check-wheel": ["crates", "bindings/python"],
    "check-empty-child": ["crates", "swift", "android"],
    "check-pane-ladder": ["crates", "swift", "docs"],
    "check-table-tier": ["crates", "swift", "docs"],
    # check-keyed's fixture. A REAL entry on purpose: a self-test stamping
    # under a live gate's name would make the next KAYA_FAST run skip it.
    "keyed-selftest": [],
}

# The BUILT files each artifact gate reads. The key mixes each one's
# EMBEDDED build-id marker, never its raw bytes — a raw-byte key was
# measured never hitting at all (docs/deferred.md's 2026-08-20 keyed-cache
# entry). KAYA_GATE_ARTIFACT_ROOT re-roots these paths for check-keyed's
# self-test and nothing else.
ARTIFACT_GATES = {
    "check-abort": ["target/debug/libkaya.dylib"],
    "check-wheel": ["target/debug/libkaya.dylib"],
    "check-empty-child": ["target/debug/libkaya.dylib"],
    "check-pane-ladder": ["target/debug/libkaya.dylib"],
    "check-table-tier": ["target/debug/libkaya.dylib"],
}

PREFIX = b"kaya-build-id:"


def embedded_ids(p):
    """Every build-id marker in the file, sorted."""
    blob = p.read_bytes()
    found, at = set(), 0
    while (at := blob.find(PREFIX, at)) != -1:
        found.add(bytes(blob[at + len(PREFIX): at + len(PREFIX) + 16]))
        at += len(PREFIX)
    return sorted(found)


# Anything skipped here is invisible to the id, so the list stays short.
SKIP_DIRS = {"target", "target-linux", "__pycache__", ".git"}


def git_files(names):
    """The tracked and not-ignored files under `names`, or None if git
    cannot answer. Preferred over walking for GATE keys, whose roots hold
    build directories a hand-kept denylist would have to chase forever.

    safe.directory: inside the container the repo is mounted with a
    foreign owner, and git refuses to operate on it otherwise."""
    cmd = ["git", "-c", "safe.directory=*", "ls-files", "-z", "-c", "-o",
           "--exclude-standard", "--", *names]
    try:
        out = subprocess.run(cmd, cwd=root, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    # `-c` reports index entries whose worktree file is gone.
    return sorted(p for p in (root / n for n in
                              out.stdout.decode().split("\0") if n)
                  if p.is_file())


def files(names):
    out = []
    for name in names:
        p = root / name
        if p.is_file():
            out.append(p)
        elif p.is_dir():
            for f in p.rglob("*"):
                if f.is_file() and not (SKIP_DIRS
                                        & set(f.relative_to(root).parts)):
                    out.append(f)
        else:
            sys.exit(f"build-id: {name} is neither file nor directory "
                     f"under {root}")
    # Sorted by path so the id does not depend on directory order.
    return sorted(out)


def digest(paths):
    h = hashlib.sha256()
    for f in paths:
        rel = str(f.relative_to(root)).replace("\\", "/")
        body = f.read_bytes()
        # Length-delimited: a rename or a byte crossing a file boundary
        # has to change the digest.
        h.update(f"{rel}\0{len(body)}\0".encode())
        h.update(body)
    return h.hexdigest()[:16]


def build_id(component):
    return digest(files(COMPONENTS[component]))


def gate_key(name):
    # tools/ and the flake ride every gate key: a changed script, or a
    # changed toolchain, must not report the verdict its old self reached.
    names = ["tools", "flake.nix", "flake.lock"] + GATES[name]
    paths = git_files(names)
    if paths is None:
        # No git: the walk's key differs from git's and includes build
        # output, so the cache stops hitting — slow, never wrong.
        paths = files([n for n in names if (root / n).exists()])
    h = hashlib.sha256(digest(paths).encode())
    # The artifact half: see ARTIFACT_GATES for why never the raw bytes.
    artifact_root = pathlib.Path(
        os.environ.get("KAYA_GATE_ARTIFACT_ROOT", root))
    for rel in ARTIFACT_GATES.get(name, []):
        p = artifact_root / rel
        h.update(f"artifact:{rel}\0".encode())
        if not p.is_file():
            h.update(b"absent")
            continue
        ids = embedded_ids(p)
        h.update(b"|".join(ids) if ids else b"unmarked")
    return h.hexdigest()[:16]


def main(args):
    if not args:
        sys.exit("usage: build-id.py <component> | --gate NAME "
                 "| --verify [--component NAME] FILE...")

    if args[0] == "--gate":
        if len(args) != 2 or args[1] not in GATES:
            sys.exit(f"build-id: --gate wants one of: "
                     f"{', '.join(sorted(GATES))}")
        print(gate_key(args[1]))
        return 0

    if args[0] == "--gate-artifacts":
        # The census surface for check-keyed's clause 6: which built
        # files ride this gate's key. Empty output means none.
        if len(args) != 2 or args[1] not in GATES:
            sys.exit(f"build-id: --gate-artifacts wants one of: "
                     f"{', '.join(sorted(GATES))}")
        for rel in ARTIFACT_GATES.get(args[1], []):
            print(rel)
        return 0

    if args[0] != "--verify":
        if args[0] not in COMPONENTS:
            sys.exit(f"build-id: unknown component {args[0]!r} "
                     f"(have: {', '.join(COMPONENTS)})")
        print(build_id(args[0]))
        return 0

    # The marker is baked in by crates/kaya/build.rs for the core and
    # tools/swiftui/build-dylib.sh for the interpreter. ONE prefix for
    # every component, with --component saying which hash to expect:
    # per-component prefixes would read a wrong-component marker as "no
    # build id" rather than as a mismatch.
    component = "core"
    if len(args) > 2 and args[1] == "--component":
        component = args[2]
        if component not in COMPONENTS:
            sys.exit(f"build-id: unknown component {component!r} "
                     f"(have: {', '.join(COMPONENTS)})")
        args = args[:1] + args[3:]
    want = build_id(component).encode()
    status = 0
    for name in args[1:]:
        p = pathlib.Path(name)
        if not p.is_file():
            print(f"build-id: {name}: MISSING — the build that produces "
                  f"it did not run", file=sys.stderr)
            status = 1
            continue
        # An apk's dex members are compressed, and which classes*.dex a
        # string lands in is not stable, so read them all.
        if zipfile.is_zipfile(p):
            with zipfile.ZipFile(p) as z:
                blob = b"".join(z.read(n) for n in z.namelist()
                                if n.endswith(".dex"))
        else:
            blob = p.read_bytes()
        found, at = set(), 0
        while (at := blob.find(PREFIX, at)) != -1:
            found.add(blob[at + len(PREFIX): at + len(PREFIX) + 16])
            at += len(PREFIX)
        if want in found:
            continue
        status = 1
        if not found:
            print(f"build-id: {name}: NO build id — nothing here was "
                  f"built from {component}", file=sys.stderr)
        else:
            # A bare --verify defaults to core, so running it on the
            # swiftui dylib can never pass: say which question to ask.
            others = [c for c in COMPONENTS if c != component
                      and build_id(c).encode() in found]
            carried = ", ".join(sorted(f.decode("ascii", "replace")
                                       for f in found))
            print(
                f"build-id: {name}: STALE — carries {carried}, but "
                f"{component} in this tree is {want.decode()}",
                file=sys.stderr,
            )
            if others:
                print(
                    f"  BUT that is {others[0]}'s CURRENT id — this file "
                    f"looks like the {others[0]} component; did you mean "
                    f"--component {others[0]}?",
                    file=sys.stderr,
                )
            else:
                print(
                    "  the build step that should have refreshed it did "
                    "not run, or failed with its exit status masked",
                    file=sys.stderr,
                )
    return status


# Importable on purpose: tools/lib/keyed-inputs.py loads this module for
# GATES/ARTIFACT_GATES rather than parsing the text.
if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

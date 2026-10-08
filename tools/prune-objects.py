#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# docs/traps.md, the stale split-debuginfo objects (2026-10-08).
#
#   tools/prune-objects.py              self-test, then prune target/
#   tools/prune-objects.py --target D   the same against another target dir

import fcntl
import os
import re
import struct
import time

SHAPE = re.compile(r"^(?P<stem>[^.]+)\.[0-9a-z]+\.(?P<session>[0-9a-z]+)\.rcgu\.o$")
MH_MAGIC_64 = 0xFEEDFACF
LC_SYMTAB = 0x2
N_OSO = 0x66
LOCK_WAIT = 5


def debug_map(path):
    """The object names a Mach-O artifact's N_OSO stabs point at."""
    with open(path, "rb") as f:
        head = f.read(32)
        if len(head) < 32 or struct.unpack_from("<I", head)[0] != MH_MAGIC_64:
            return set()
        ncmds, sizeofcmds = struct.unpack_from("<II", head, 16)
        cmds = f.read(sizeofcmds)
        off = 0
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", cmds, off)
            if cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", cmds, off + 8)
                break
            off += size
        else:
            return set()
        f.seek(symoff)
        syms = f.read(nsyms * 16)
        f.seek(stroff)
        strs = f.read(strsize)
    out = set()
    for strx, ntype, _sect, _desc, _value in struct.iter_unpack("<IBBHQ", syms):
        if ntype == N_OSO:
            out.add(os.path.basename(strs[strx:strs.index(b"\0", strx)].decode("utf-8")))
    return out


def artifacts(directory, stem):
    for name in (stem, f"lib{stem}.dylib", f"{stem}.dylib"):
        if os.path.isfile(os.path.join(directory, name)):
            yield os.path.join(directory, name)


def stale(directory):
    """Every incremental object no artifact in its directory names, and the kept count."""
    stems = {}
    for entry in os.scandir(directory):
        m = SHAPE.match(entry.name)
        if m is not None:
            stems.setdefault(m["stem"], {}).setdefault(m["session"], []).append(entry.name)
    out, kept = [], 0
    for stem, sessions in stems.items():
        found = list(artifacts(directory, stem))
        if found and len(sessions) == 1:
            kept += sum(len(v) for v in sessions.values())
            continue
        named = set().union(*(debug_map(a) for a in found))
        for names in sessions.values():
            for name in names:
                if name in named:
                    kept += 1
                else:
                    out.append(os.path.join(directory, name))
    return out, kept, len(stems)


def object_dirs(target):
    for profile in sorted(target.glob("debug")) + sorted(target.glob("*/debug")):
        dirs = [profile / leaf for leaf in ("deps", "examples") if (profile / leaf).is_dir()]
        if dirs:
            yield profile, dirs


def cargo_lock(profile, wait):
    """Cargo's own lock on this profile directory, or None after `wait` seconds."""
    f = open(profile / ".cargo-lock", "a", encoding="utf-8")  # noqa: SIM115
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f
        except BlockingIOError:
            if time.monotonic() >= deadline:
                f.close()
                return None
            time.sleep(0.5)


def prune(target, say=print, wait=LOCK_WAIT):
    total = 0
    for profile, dirs in object_dirs(target):
        if not any(stale(d)[0] for d in dirs):
            continue
        lock = cargo_lock(profile, wait)
        if lock is None:
            say(f"prune-objects: {profile}: SKIPPED — a cargo build held its lock for "
                f"{wait}s, and its objects are the ones being written; the next "
                f"tools/gates.py build prunes it")
            continue
        with lock:
            for d in dirs:
                t0 = time.monotonic()
                doomed, kept, stems = stale(d)
                freed = 0
                for path in doomed:
                    st = os.lstat(path)
                    freed += st.st_blocks * 512 if st.st_nlink == 1 else 0
                    os.unlink(path)
                if doomed:
                    say(f"prune-objects: {d}: removed {len(doomed):,} stale objects "
                        f"({freed / 1e9:.2f} GB not shared with the incremental cache), "
                        f"kept {kept:,} named by an artifact, "
                        f"{stems} stems, {time.monotonic() - t0:.1f}s")
                total += len(doomed)
    return total


def macho(path, objects):
    """A minimal Mach-O whose debug map names `objects`."""
    strtab = b"\0" + b"".join(o.encode("utf-8") + b"\0" for o in objects)
    nlist, strx = b"", 1
    for o in objects:
        nlist += struct.pack("<IBBHQ", strx, N_OSO, 0, 1, 0)
        strx += len(o) + 1
    symoff = 32 + 24
    symtab = struct.pack("<IIIIII", LC_SYMTAB, 24, symoff, len(objects),
                         symoff + len(nlist), len(strtab))
    header = struct.pack("<IiiIIIII", MH_MAGIC_64, 0x0100000C, 0, 2, 1, 24, 0, 0)
    path.write_bytes(header + symtab + nlist + strtab)


def plant(d):
    """A lib with three sessions whose artifact names the MIDDLE one, all
    at one mtime (the incremental cache hard-links unchanged objects, so
    an object's mtime says nothing about its session); a test binary with
    two; an orphan stem with two sessions and one with one; a
    single-session proc macro; two non-incremental
    objects; an rlib."""
    d.mkdir(parents=True)
    lib = {s: [f"kaya.{c:025d}.{s}.rcgu.o" for c in range(256)]
           for s in ("0aaaaaa", "0bbbbbb", "0cccccc")}
    test = {s: [f"kaya-0123456789abcdef.{c:025d}.{s}.rcgu.o" for c in range(8)]
            for s in ("1dddddd", "1eeeeee")}
    orphan = [f"kaya-fedcba9876543210.{c:025d}.{s}.rcgu.o" for c in range(4)
              for s in ("2ffffff", "2gggggg")]
    lone = [f"kaya-1111111111111111.{c:025d}.4iiiiii.rcgu.o" for c in range(4)]
    derive = [f"kaya_derive-aaaaaaaaaaaaaaaa.{c:025d}.3hhhhhh.rcgu.o" for c in range(4)]
    other = [f"hashbrown-6bc99d7e977483f0.hashbrown.f6693d50bee22181-cgu.{c}.rcgu.o"
             for c in range(2)] + ["libkaya.rlib"]
    for name in [*sum(lib.values(), []), *sum(test.values(), []), *orphan, *lone, *derive, *other]:
        (d / name).write_bytes(b"")
        os.utime(d / name, (1e9, 1e9))
    macho(d / "libkaya.dylib", [str(d / n) for n in lib["0bbbbbb"]])
    macho(d / "kaya-0123456789abcdef", [str(d / n) for n in test["1dddddd"]])
    macho(d / "libkaya_derive-aaaaaaaaaaaaaaaa.dylib", [str(d / n) for n in derive])
    left = {*lib["0bbbbbb"], *test["1dddddd"], *derive, *other, "libkaya.dylib",
            "kaya-0123456789abcdef", "libkaya_derive-aaaaaaaaaaaaaaaa.dylib"}
    return 256 * 2 + 8 + 8 + 4, left


def findings(prune_fn, scratch, label, held=False):
    target = scratch / label
    want_gone, want_left = plant(target / "debug" / "deps")
    if held:
        want_gone, want_left = 0, {p.name for p in (target / "debug" / "deps").iterdir()}
    said = []
    blocker = open(target / "debug" / ".cargo-lock", "a", encoding="utf-8")  # noqa: SIM115
    if held:
        fcntl.flock(blocker, fcntl.LOCK_EX)
    try:
        removed = prune_fn(target, said.append, wait=1)
    finally:
        blocker.close()
    left = {p.name for p in (target / "debug" / "deps").iterdir()}
    out = []
    if removed != want_gone:
        out.append(f"removed {removed} objects, wanted {want_gone}")
    if left - want_left:
        out.append(f"stale kept: {len(left - want_left)}")
    if want_left - left:
        out.append(f"named objects deleted: {len(want_left - left)}")
    if held and not any("SKIPPED" in s for s in said):
        out.append("a held cargo lock was not reported")
    if not held and not any(f"removed {want_gone:,} stale objects" in s for s in said):
        out.append("the prune did not say what it removed")
    return out


def selftest(gate):
    scratch = gate.scratch()
    for held in (False, True):
        for f in findings(prune, scratch, f"real-{held}", held):
            gate.finding(f"self-test: the prune itself is wrong: {f}")
    own = gate.read(pathlib.Path(__file__).resolve())
    cuts = (
        ("N1 reads no debug map", r"if ntype == N_OSO:\n", "if ntype == -1:\n",
         False, "named objects deleted"),
        ("N2 takes a lone session on trust without its artifact",
         r"if found and len\(sessions\) == 1:", "if len(sessions) == 1:",
         False, "stale kept"),
        ("N3 reads every object as incremental",
         r'\(\?P<stem>\[\^\.\]\+\)\\\.\[0-9a-z\]\+\\\.\(\?P<session>\[0-9a-z\]\+\)',
         r"(?P<stem>[^.]+)\\.(?P<session>.+)", False, "named objects deleted"),
        ("N4 deletes nothing", r"os\.unlink\(path\)", "os.lstat(path)", False, "stale kept"),
        ("N5 says nothing", r"if doomed:\n {20}say\(", "if not doomed:\n" + " " * 20 + "say(",
         False, "did not say"),
        ("N6 ignores cargo's lock", r"fcntl\.flock\(f, fcntl\.LOCK_EX \| fcntl\.LOCK_NB\)",
         "pass", True, "removed 532 objects"),
    )
    for i, (label, pattern, repl, held, want) in enumerate(cuts):
        text = gate.doctor(label, own, pattern, repl)
        space = {"__name__": f"prune_objects_doctored_{i}", "__file__": __file__}
        exec(compile(text, f"<{label}>", "exec"), space)  # noqa: S102
        gate.negative(label, lambda s=space, n=i, h=held: findings(s["prune"], scratch,
                                                                  f"neg{n}", h),
                      want=want)
    gate.negatives_ran(len(cuts))


def main():
    gate = Gate("prune-objects")
    args = sys.argv[1:]
    target = ROOT / "target"
    if "--target" in args:
        target = pathlib.Path(args[args.index("--target") + 1])
    if not target.is_dir():
        gate.refuse(f"{target} is not a directory — nothing built, nothing to prune")
    selftest(gate)
    if gate.status:
        gate.verdict()
    t0 = time.monotonic()
    removed = prune(target)
    gate.verdict(f"{removed:,} stale objects removed under {target}, "
                 f"{time.monotonic() - t0:.1f}s")


if __name__ == "__main__":
    main()

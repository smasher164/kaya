#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# THE MAC LANE RUNS BOTH macOS DESIGN GENERATIONS, and both halves must
# stay populated — either could empty out with no diff in this repo
# (CLAUDE.md's gate list; docs/deferred.md's standing constraint: never
# bump the flake SDK without leaving a compat leg). The Mach-O is parsed
# by hand because `vtool`/`otool` are xcrun shims that cannot find their
# tool here.
#
# ENV HYGIENE — THE MOVE THAT LOOKS RIGHT AND IS BACKWARDS. `env -u
# DEVELOPER_DIR -u SDKROOT cc probe.c` does NOT neutralise a caller's
# stray environment: those two are how the apple-sdk setup hook hands
# the SDK to clang, so unsetting them drops the flake's SDK and stamps
# 14.4 (docs/chrome/sdk-bump-scout.md). The compile is NORMALISED
# instead, from mkShell's own `buildInputs`; MACOSX_DEPLOYMENT_TARGET
# has no second witness and is printed in the minos failure.
#
# TEST-ONLY SEAM: KAYA_DESIGN_GEN_SUBST="leg=path,…" replaces the binary
# a named leg reads. An unrecognised name is a hard failure: a typo'd
# substitution would make a watched red vacuous.

import os
import platform as platform_mod
import re
import shutil
import struct
import subprocess

if platform_mod.system() != "Darwin":
    print(f"check-design-generation: this gate reads macOS Mach-O stamps "
          f"and builds probes with the mac toolchain; it belongs to the "
          f"mac sweep (tools/gates.py) and has nothing to say on "
          f"{platform_mod.system()}. Refusing rather than passing.",
          file=sys.stderr)
    sys.exit(1)

# The flake's OWN SDK — see the ENV HYGIENE note above.
declared = os.environ.get("buildInputs", "")
sdks = [p for p in declared.split()
        if re.search(r"apple-sdk-[0-9][^/]*$", p.rstrip("/"))]
if len(sdks) != 1:
    print(f"check-design-generation: mkShell exported "
          f"buildInputs={declared!r}, which names {len(sdks)} apple-sdk "
          f"path(s) — this gate needs exactly 1 to know which SDK the "
          f"shell links against, and will not guess. flake.nix's "
          f"`buildInputs = [ pkgs.apple-sdk_26 ];` is what puts it there; "
          f"the `packages = [ ... ]` spelling puts the SDK in the build "
          f"role instead, where the setup hook clashes with the stdenv's "
          f"default and breaks cc outright (measured, "
          f"docs/chrome/sdk-bump-scout.md §2).", file=sys.stderr)
    sys.exit(1)
flake_sdk = sdks[0].rstrip("/")

# ------------------------------------------------------------ the table
#
# DECLARED_READS is the census: the verdict refuses unless exactly this
# many stamps were read.
DECLARED_READS = 6

MODERN_FLOOR = (26, 0)   # sdk >= this is macOS 26's modern generation

status = 0


def fail(msg):
    global status
    print(f"check-design-generation: {msg}", file=sys.stderr)
    status = 1


# ------------------------------------------------------- the Mach-O read

FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH_MAGIC_64, MH_MAGIC_32 = 0xFEEDFACF, 0xFEEDFACE
CPU_TYPE_ARM64 = 0x0100000C
LC_VERSION_MIN_MACOSX, LC_BUILD_VERSION = 0x24, 0x32
PLATFORM_MACOS = 1


def ver(v):
    """LC_BUILD_VERSION packs x.y.z into a u32 as xxxx.yy.zz."""
    return (v >> 16, (v >> 8) & 0xFF, v & 0xFF)


def show(v):
    return f"{v[0]}.{v[1]}.{v[2]}"


def floor_of(v):
    """A two-component threshold, spelled the way the tables spell it."""
    return f"{v[0]}.{v[1]}"


def arm64_offset(fh):
    """Where the arm64 Mach-O starts: 0 for a thin file, the matching
    slice for a fat one. The vendor hosts are the reason — a universal
    binary's x86_64 slice can carry a different stamp entirely, and the
    lane runs the arm64 one."""
    fh.seek(0)
    head = fh.read(8)
    if len(head) < 8:
        return None, f"file is {len(head)} bytes — not a Mach-O"
    magic, count = struct.unpack(">2I", head)
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return 0, None
    for _ in range(count):
        if magic == FAT_MAGIC:
            cpu, _sub, off, _size, _align = struct.unpack(">5I",
                                                          fh.read(20))
        else:
            cpu, _sub, off, _size, _align, _res = struct.unpack(
                ">IIQQII", fh.read(32))
        if cpu == CPU_TYPE_ARM64:
            return off, None
    return None, f"fat binary with {count} slice(s), none of them arm64"


def stamp(path):
    """(platform, minos, sdk, which load command) or (None, why)."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(2)
            if head == b"#!":
                fh.seek(0)
                line = fh.readline(300).decode("utf-8", "replace").strip()
                return None, (f"is a script, not a Mach-O (first line: "
                              f"{line!r}) — a wrapper moved in front of "
                              f"the real host; teach this gate to follow "
                              f"it rather than let the read go missing")
            off, why = arm64_offset(fh)
            if off is None:
                return None, why
            fh.seek(off)
            raw = fh.read(32)
            magic = struct.unpack("<I", raw[:4])[0]
            if magic == MH_MAGIC_64:
                hdr = 32
            elif magic == MH_MAGIC_32:
                hdr = 28
            else:
                return None, (f"not a little-endian Mach-O "
                              f"(magic 0x{magic:08x})")
            ncmds = struct.unpack("<I", raw[16:20])[0]
            pos = off + hdr
            for _ in range(ncmds):
                fh.seek(pos)
                cmd, cmdsize = struct.unpack("<2I", fh.read(8))
                if cmdsize < 8:
                    return None, (f"load command 0x{cmd:x} has cmdsize "
                                  f"{cmdsize}")
                if cmd == LC_BUILD_VERSION:
                    plat, minos, sdk, _ntools = struct.unpack("<4I",
                                                              fh.read(16))
                    return (plat, ver(minos), ver(sdk),
                            "LC_BUILD_VERSION"), None
                if cmd == LC_VERSION_MIN_MACOSX:
                    minos, sdk = struct.unpack("<2I", fh.read(8))
                    return (PLATFORM_MACOS, ver(minos), ver(sdk),
                            "LC_VERSION_MIN_MACOSX"), None
                pos += cmdsize
            return None, (f"carries neither LC_BUILD_VERSION nor "
                          f"LC_VERSION_MIN_MACOSX in {ncmds} load "
                          f"commands")
    except OSError as exc:
        return None, f"could not be read ({exc.strerror})"


with scratch_dir("check-design-generation-") as tmp:
    # 1. THE FLAKE-LINKED PROBE, compiled here and now: reading target/'s
    #    guests would make this a stale-artifact reader.
    (tmp / "probe.c").write_text("int main(void) { return 0; }\n",
                                 encoding="utf-8")
    cc_env = dict(
        os.environ, DEVELOPER_DIR=flake_sdk,
        SDKROOT=f"{flake_sdk}/Platforms/MacOSX.platform/Developer/SDKs/"
                f"MacOSX.sdk")
    cc = subprocess.run(
        ["cc", str(tmp / "probe.c"), "-o", str(tmp / "probe-flake-cc")],
        env=cc_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", check=False)
    if cc.returncode != 0:
        print(f"check-design-generation: the flake-linked C probe did not "
              f"compile with DEVELOPER_DIR={flake_sdk} — so nothing below "
              f"could be measured, and this gate refuses rather than skip "
              f"the modern half. cc said:", file=sys.stderr)
        sys.stderr.write(cc.stderr)
        sys.exit(1)

    # 2. THE SWIFT PROBE, through kaya_swiftc as the swift legs and the
    #    SwiftUI interpreter are. The toolchain is RESOLVED in a fresh
    #    shell, never inherited: SWIFTC/SWIFT_DEVELOPER_DIR are dropped so
    #    a caller carrying one from another build cannot decide which SDK
    #    this gate's swift half measured.
    (tmp / "probe.swift").write_text(
        'print("kaya design-generation probe")\n', encoding="utf-8")
    swift_env = {k: v for k, v in os.environ.items()
                 if k not in ("SWIFTC", "SWIFT_DEVELOPER_DIR")}
    swiftc = subprocess.run(
        ["bash", "-c",
         'source "$1/tools/lib/swift-toolchain.sh" && '
         'kaya_swiftc "$2" -o "$3"',
         "swift-toolchain", str(ROOT), str(tmp / "probe.swift"),
         str(tmp / "probe-swift")],
        env=swift_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", check=False)
    if swiftc.returncode != 0:
        print("check-design-generation: the swift probe did not compile "
              "through kaya_swiftc (tools/lib/swift-toolchain.sh) — the "
              "modern half's second read is impossible, and a missing "
              "toolchain is a refusal here, never a silent skip. swiftc "
              "said:", file=sys.stderr)
        sys.stderr.write(swiftc.stderr)
        sys.exit(1)

    # name, side, how, what, extra rules, what the read stands for
    LEGS = [
        ("flake-cc", "modern", "file", str(tmp / "probe-flake-cc"),
         {"minos_below": MODERN_FLOOR},
         "the rust, go, c, ocaml and haskell legs: their main executables "
         "are linked by this shell's cc, and flake.nix's buildInputs SDK "
         "is what stamps them"),
        ("swift", "modern", "file", str(tmp / "probe-swift"), {},
         "the swift legs (validate-mac.py's build_swift) and the SwiftUI "
         "interpreter, both built through kaya_swiftc against Apple's "
         "SDK"),
        ("python", "compat", "which", "python3", {},
         "validate-mac.py's python legs — `python3 "
         "guests/python/<scene>.py`, a nixpkgs-prebuilt host kaya does "
         "not link"),
        ("dotnet", "compat", "which", "dotnet", {},
         "validate-mac.py's csharp legs — `dotnet exec $CS_GUEST`, a "
         "Microsoft-built host nix only repackages"),
        ("java", "compat", "which", "java", {},
         "validate-mac.py's java legs — `java -XstartOnFirstThread -cp "
         "target/java-guests …`, an Azul-built host"),
        ("node", "compat", "which", "node", {},
         "validate-mac.py's js legs — `node guests/js/<scene>.ts`, a "
         "nixpkgs-prebuilt host kaya does not link (docs/js-plan.md §1)"),
    ]

    # -------------------------------------------------- the test seam
    SUBST = {}
    for item in os.environ.get("KAYA_DESIGN_GEN_SUBST", "").split(","):
        if not item.strip():
            continue
        name, sep, path = item.partition("=")
        if not sep:
            fail(f"KAYA_DESIGN_GEN_SUBST entry {item!r} is not leg=path")
            continue
        SUBST[name.strip()] = path.strip()

    known = {leg[0] for leg in LEGS}
    for name in sorted(set(SUBST) - known):
        fail(f"KAYA_DESIGN_GEN_SUBST names {name!r}, which is not a leg "
             f"in this table ({', '.join(sorted(known))}). A substitution "
             f"that lands nowhere would make the negative test that set "
             f"it vacuous, so it is a failure here.")

    # ---------------------------------------------------------- reads
    if len(LEGS) != DECLARED_READS:
        fail(f"the table holds {len(LEGS)} legs but DECLARED_READS says "
             f"{DECLARED_READS} — the declaration and the list must be "
             f"one list")

    reads = 0
    measured = {"modern": [], "compat": []}

    for name, side, how, what, rules, stands_for in LEGS:
        if name in SUBST:
            path = SUBST[name]
            origin = "KAYA_DESIGN_GEN_SUBST (test-only seam)"
            print(f"check-design-generation: SUBSTITUTED {name} -> {path} "
                  f"[{origin}]")
        elif how == "file":
            path, origin = what, "probe compiled by this gate"
        else:
            found = shutil.which(what)
            if found is None:
                fail(f"{name} ({side} side): `{what}` is not on PATH, so "
                     f"the read the table declares is impossible. This "
                     f"gate reads the hosts the mac lane launches — "
                     f"{stands_for} — and a host it cannot find is a "
                     f"refusal, never a skip.")
                continue
            path = os.path.realpath(found)
            origin = f"`{what}` on PATH -> {found}"
        st, why = stamp(path)
        if st is None:
            fail(f"{name} ({side} side): {path} {why}. Resolved from "
                 f"{origin}; it stands for {stands_for}.")
            continue
        plat, minos, sdk, which = st
        reads += 1
        seen = "modern" if sdk >= MODERN_FLOOR else "compat"
        measured[seen].append((name, show(sdk)))
        print(f"check-design-generation: {name:9s} {seen:6s} sdk "
              f"{show(sdk):8s} minos {show(minos):8s} platform {plat} "
              f"{which}  <- {origin}")

        if plat != PLATFORM_MACOS:
            fail(f"{name}: {path} is stamped for platform {plat}, not "
                 f"macOS ({PLATFORM_MACOS}) — the generation SwiftUI "
                 f"picks is a macOS fact and this read cannot speak to it")
        if seen != side:
            if side == "modern":
                fail(f"{name}: measured sdk {show(sdk)} ({which}, minos "
                     f"{show(minos)}) at {path}, but the table declares "
                     f"it MODERN, which needs sdk >= "
                     f"{floor_of(MODERN_FLOOR)}. A host stamped below "
                     f"that runs SwiftUI's COMPATIBILITY generation. This "
                     f"leg stands for {stands_for} — so the flake's "
                     f"`buildInputs = [ pkgs.apple-sdk_26 ]` is the line "
                     f"to look at (this gate normalised DEVELOPER_DIR to "
                     f"{flake_sdk} from mkShell's own buildInputs).")
            else:
                fail(f"{name}: measured sdk {show(sdk)} ({which}, minos "
                     f"{show(minos)}) at {path}, but the table declares "
                     f"it COMPAT, which needs sdk < "
                     f"{floor_of(MODERN_FLOOR)}. This host has moved to "
                     f"the MODERN generation — it stands for "
                     f"{stands_for}, and kaya does not link it, so a "
                     f"vendor or nixpkgs rebuild moved it, not a kaya "
                     f"commit. The ledger's standing constraint "
                     f"(docs/deferred.md) requires the compat generation "
                     f"to keep a leg: it is where the Button measurement "
                     f"bug class lives (docs/traps.md). Move this leg's "
                     f"side in the table only with a compat leg left "
                     f"standing.")
        floor = rules.get("minos_below")
        if floor is not None and minos >= floor:
            fail(f"{name}: measured minos {show(minos)} ({which}) at "
                 f"{path}, and the MODERN half requires minos < "
                 f"{floor_of(floor)} — the deployment floor of kaya-built "
                 f"guests rose, so they no longer launch on any macOS "
                 f"older than {show(minos)}. flake.nix omits "
                 f"darwinMinVersionHook on purpose (the sdk field alone "
                 f"buys the design generation), so look for that hook "
                 f"arriving in the flake, or for MACOSX_DEPLOYMENT_TARGET "
                 f"being set outside it. This gate cannot tell those two "
                 f"apart from a stamp; what it can see is that it "
                 f"inherited MACOSX_DEPLOYMENT_TARGET="
                 f"{os.environ.get('MACOSX_DEPLOYMENT_TARGET', '<unset>')}"
                 f".")

        # Second witness for a probe this gate compiled: the SDK store
        # path names its version. Skipped for a substituted leg.
        if name == "flake-cc" and name not in SUBST:
            declared_sdk = re.search(r"apple-sdk-([0-9]+(?:\.[0-9]+)*)",
                                     flake_sdk)
            if declared_sdk is None:
                fail(f"the SDK store path {flake_sdk} carries no version "
                     f"to cross-check the probe against")
            else:
                want = tuple(int(p) for p in
                             declared_sdk.group(1).split("."))[:2]
                if sdk[:len(want)] != want:
                    fail(f"{name}: the shell declares {flake_sdk} but the "
                         f"probe it compiled stamps sdk {show(sdk)} — the "
                         f"compile did not honour the DEVELOPER_DIR this "
                         f"gate set, so the number above is not a "
                         f"measurement of the flake's SDK")

# ------------------------------------------------------------ the verdict

for side in ("modern", "compat"):
    if not measured[side]:
        fail(f"the {side.upper()} half of the table is EMPTY — no leg "
             f"measured on that side. The mac lane must exercise BOTH "
             f"macOS design generations (docs/deferred.md's standing "
             f"constraint); a lane running one of them is a lane that "
             f"cannot see the other's bug classes.")

if reads != DECLARED_READS:
    fail(f"REFUSING A VERDICT: declared {DECLARED_READS} reads, made "
         f"{reads}. The findings above say which leg went unread; a sweep "
         f"that reads fewer stamps than it declared cannot report on a "
         f"table it did not finish.")

if status == 0:
    print("check-design-generation: OK ({}/{} reads — modern: {}; "
          "compat: {})".format(
              reads, DECLARED_READS,
              ", ".join(f"{n} sdk {v}" for n, v in measured["modern"]),
              ", ".join(f"{n} sdk {v}" for n, v in measured["compat"])))
else:
    print("check-design-generation: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)

#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# THE MAC LANE RUNS BOTH macOS DESIGN GENERATIONS, AND NOTHING SAID SO.
#
# SwiftUI picks its design generation from the MAIN EXECUTABLE's
# LC_BUILD_VERSION — the sdk field, not minos (kaya's own measurement,
# docs/traps.md; a binary stamped minos 14 + sdk 26.5 takes the modern
# path). So the generation a leg exercises is decided by whoever LINKED
# its host process, and the mac lane's legs have two different linkers:
#
#   MODERN   the legs kaya links itself — rust, go, c, ocaml, haskell go
#            through this shell's cc, and flake.nix's
#            `buildInputs = [ pkgs.apple-sdk_26 ]` is what stamps them
#            sdk 26.5 — plus swift, which builds through kaya_swiftc
#            against the system toolchain and was modern already.
#   COMPAT   the legs whose main executable is a VENDOR-BUILT host kaya
#            never links: python3, the .NET host, the zulu JVM. They are
#            compat by accident of someone else's build, not by choice.
#
# The ledger's standing constraint (docs/deferred.md, "do not bump the
# flake SDK without preserving a compat-generation leg") requires BOTH
# halves to stay populated: the compat generation is where the Button
# measurement bug class lives (docs/traps.md — sizeThatFits answers with
# borderless metrics while the bezeled control draws, so captions
# ellipsize), and the native-kit button bridges are load-bearing
# indefinitely. Before this gate that constraint was a comment in
# flake.nix and a paragraph in the ledger. Either half could empty out
# with no diff in this repo at all — a nixpkgs bump moves the stdenv SDK
# under python3, Azul or Microsoft rebuild a host, someone writes the
# `packages =` spelling of the SDK line — and nothing would have gone
# red. That is precisely the guard-you-have-to-remember shape invariant 3
# rejects, so: measured on every sweep, both halves, or no verdict.
#
# WHAT IT MEASURES, AND WHAT IT DELIBERATELY DOES NOT.
#
# It measures COMPILES, not build outputs. A stamp is a property of the
# link that produced it, so the modern half is two probes built here and
# now — a 3-line C file through the shell's own `cc` (the linker driver
# every kaya-built mac leg's main executable goes through: rustc, cgo,
# ocamlopt and ghc all shell out to it) and a one-line Swift file through
# kaya_swiftc (tools/lib/swift-toolchain.sh, which is what
# validate-mac.sh and swiftui/build-dylib.sh build with). Reading
# target/'s guests instead would make the gate a stale-artifact reader
# that passes on a tree nobody has built, and `vtool`/`otool` are not
# reachable here anyway — inside the dev shell they are xcrun shims that
# cannot find their tool. The reader below is 60 lines of struct.unpack
# and was cross-checked field-for-field against `otool -l` on six files.
#
# ENV HYGIENE — AND THE MOVE THAT LOOKS RIGHT AND IS BACKWARDS.
# `env -u DEVELOPER_DIR -u SDKROOT cc probe.c` does NOT neutralise a
# caller's stray environment. Measured on this tree: it drops the flake's
# SDK entirely and stamps 14.4, because DEVELOPER_DIR/SDKROOT are exactly
# how the apple-sdk derivation's setup hook hands the SDK to clang. So
# the probe compile is NORMALISED rather than cleared, from a witness a
# caller does not set: mkShell exports its own `buildInputs` attribute,
# which is flake.nix's declaration verbatim. No apple-sdk there is a
# refusal, not a guess.
#
# MACOSX_DEPLOYMENT_TARGET has no second witness — it comes from
# stdenv.hostPlatform.darwinMinVersion, not from any attribute in
# flake.nix — so it is inherited, and printed inside the minos failure
# sentence so a reader can tell a flake regression from a stray export.
#
# TEST-ONLY SEAM: KAYA_DESIGN_GEN_SUBST="leg=path,leg=path" replaces the
# binary a named leg reads, so the watched negatives can drive a doctored
# stamp through the real code path. It exists for those negatives and for
# nothing else; a name it does not recognise is a hard failure, because a
# typo'd substitution would make a watched red vacuous — the failure mode
# the wayland seat guard shipped twice.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if [ "$(uname -s)" != "Darwin" ]; then
    echo "check-design-generation: this gate reads macOS Mach-O stamps and builds" \
        "probes with the mac toolchain; it belongs to the mac sweep (tools/gates.sh)" \
        "and has nothing to say on $(uname -s). Refusing rather than passing." >&2
    exit 1
fi

# The swift toolchain is RESOLVED here, never inherited: swift-toolchain.sh
# memoizes into SWIFTC/SWIFT_SDK_ARGS/SWIFT_DEVELOPER_DIR and returns early
# if SWIFTC is already set, so a caller carrying one from another build
# would decide which SDK this gate's swift half measured. Same rule as the
# DEVELOPER_DIR normalisation above, one toolchain over.
unset SWIFTC SWIFT_SDK_ARGS SWIFT_DEVELOPER_DIR
# shellcheck source=tools/lib/swift-toolchain.sh
source "$ROOT/tools/lib/swift-toolchain.sh"

if ! T=$(mktemp -d); then
    echo "check-design-generation: could not create a scratch directory" \
        "(TMPDIR=${TMPDIR:-<unset>}) — the two probes have nowhere to be built," \
        "so the modern half cannot be measured at all." >&2
    exit 1
fi
trap 'rm -rf "$T"' EXIT

# The flake's OWN SDK — see the ENV HYGIENE note above.
if ! flake_sdk=$(python3 - <<'PY'
import os
import re
import sys

declared = os.environ.get("buildInputs", "")
sdks = [p for p in declared.split() if re.search(r"apple-sdk-[0-9][^/]*$", p.rstrip("/"))]
if len(sdks) != 1:
    sys.exit(
        f"check-design-generation: mkShell exported buildInputs={declared!r}, which "
        f"names {len(sdks)} apple-sdk path(s) — this gate needs exactly 1 to know "
        f"which SDK the shell links against, and will not guess. flake.nix's "
        f"`buildInputs = [ pkgs.apple-sdk_26 ];` is what puts it there; the "
        f"`packages = [ ... ]` spelling puts the SDK in the build role instead, "
        f"where the setup hook clashes with the stdenv's default and breaks cc "
        f"outright (measured, scratchpad/chrome/sdk-bump-scout.md §2)."
    )
print(sdks[0].rstrip("/"))
PY
); then
    exit 1
fi

# 1. THE FLAKE-LINKED PROBE. What rust, go, c, ocaml and haskell guests
#    get when the lane links their main executables.
printf '%s\n' 'int main(void) { return 0; }' >"$T/probe.c"
if ! env DEVELOPER_DIR="$flake_sdk" SDKROOT="$flake_sdk/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
        cc "$T/probe.c" -o "$T/probe-flake-cc" 2>"$T/cc.err"; then
    echo "check-design-generation: the flake-linked C probe did not compile with" \
        "DEVELOPER_DIR=$flake_sdk — so nothing below could be measured, and this" \
        "gate refuses rather than skip the modern half. cc said:" >&2
    cat "$T/cc.err" >&2
    exit 1
fi

# 2. THE SWIFT PROBE. Same toolchain the swift mac guests and the SwiftUI
#    interpreter are built with (kaya_swiftc steers back to Apple's SDK).
printf '%s\n' 'print("kaya design-generation probe")' >"$T/probe.swift"
if ! kaya_swiftc "$T/probe.swift" -o "$T/probe-swift" 2>"$T/swiftc.err"; then
    echo "check-design-generation: the swift probe did not compile through" \
        "kaya_swiftc (tools/lib/swift-toolchain.sh) — the modern half's second" \
        "read is impossible, and a missing toolchain is a refusal here, never a" \
        "silent skip. swiftc said:" >&2
    cat "$T/swiftc.err" >&2
    exit 1
fi

python3 - "$flake_sdk" "$T/probe-flake-cc" "$T/probe-swift" <<'PY'
import os
import pathlib
import re
import shutil
import struct
import sys

flake_sdk, probe_flake_cc, probe_swift = sys.argv[1:4]

# ------------------------------------------------------------ the table
#
# DECLARED_READS is the census. It is a literal, written here, and the
# verdict at the bottom refuses unless exactly this many stamps were
# actually read — the tools/check-gates.sh and tools/tpl-surfaces.py
# precedent. A reader that resolves nothing agrees with everything: a
# machine with no dotnet, a python3 that resolved to a wrapper script, a
# loop that silently delivered four of five legs, all have to come back
# red rather than "both halves non-empty, OK".
DECLARED_READS = 5

MODERN_FLOOR = (26, 0)   # sdk >= this is macOS 26's modern generation

# name, side, how, what, extra rules, what the read stands for
LEGS = [
    ("flake-cc", "modern", "file", probe_flake_cc, {"minos_below": MODERN_FLOOR},
     "the rust, go, c, ocaml and haskell legs: their main executables are "
     "linked by this shell's cc, and flake.nix's buildInputs SDK is what "
     "stamps them"),
    ("swift", "modern", "file", probe_swift, {},
     "the swift legs (validate-mac.sh's build_swift) and the SwiftUI "
     "interpreter, both built through kaya_swiftc against Apple's SDK"),
    ("python", "compat", "which", "python3", {},
     "validate-mac.sh's python legs — `python3 guests/python/<scene>.py`, "
     "a nixpkgs-prebuilt host kaya does not link"),
    ("dotnet", "compat", "which", "dotnet", {},
     "validate-mac.sh's csharp legs — `dotnet exec $CS_GUEST`, a "
     "Microsoft-built host nix only repackages"),
    ("java", "compat", "which", "java", {},
     "validate-mac.sh's java legs — `java -XstartOnFirstThread -cp "
     "target/java-guests …`, an Azul-built host"),
]

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
            cpu, _sub, off, _size, _align = struct.unpack(">5I", fh.read(20))
        else:
            cpu, _sub, off, _size, _align, _res = struct.unpack(">IIQQII", fh.read(32))
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
                return None, (f"is a script, not a Mach-O (first line: {line!r}) — a "
                              f"wrapper moved in front of the real host; teach this "
                              f"gate to follow it rather than let the read go missing")
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
                return None, f"not a little-endian Mach-O (magic 0x{magic:08x})"
            ncmds = struct.unpack("<I", raw[16:20])[0]
            pos = off + hdr
            for _ in range(ncmds):
                fh.seek(pos)
                cmd, cmdsize = struct.unpack("<2I", fh.read(8))
                if cmdsize < 8:
                    return None, f"load command 0x{cmd:x} has cmdsize {cmdsize}"
                if cmd == LC_BUILD_VERSION:
                    plat, minos, sdk, _ntools = struct.unpack("<4I", fh.read(16))
                    return (plat, ver(minos), ver(sdk), "LC_BUILD_VERSION"), None
                if cmd == LC_VERSION_MIN_MACOSX:
                    minos, sdk = struct.unpack("<2I", fh.read(8))
                    return (PLATFORM_MACOS, ver(minos), ver(sdk),
                            "LC_VERSION_MIN_MACOSX"), None
                pos += cmdsize
            return None, (f"carries neither LC_BUILD_VERSION nor "
                          f"LC_VERSION_MIN_MACOSX in {ncmds} load commands")
    except OSError as exc:
        return None, f"could not be read ({exc.strerror})"


# ------------------------------------------------------ the test-only seam

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
    fail(f"KAYA_DESIGN_GEN_SUBST names {name!r}, which is not a leg in this table "
         f"({', '.join(sorted(known))}). A substitution that lands nowhere would "
         f"make the negative test that set it vacuous, so it is a failure here.")

# -------------------------------------------------------------- the reads

if len(LEGS) != DECLARED_READS:
    fail(f"the table holds {len(LEGS)} legs but DECLARED_READS says {DECLARED_READS} "
         f"— the declaration and the list must be one list")

reads = 0
measured = {"modern": [], "compat": []}

for name, side, how, what, rules, stands_for in LEGS:
    if name in SUBST:
        path, origin = SUBST[name], "KAYA_DESIGN_GEN_SUBST (test-only seam)"
        print(f"check-design-generation: SUBSTITUTED {name} -> {path} [{origin}]")
    elif how == "file":
        path, origin = what, "probe compiled by this gate"
    else:
        found = shutil.which(what)
        if found is None:
            fail(f"{name} ({side} side): `{what}` is not on PATH, so the read the "
                 f"table declares is impossible. This gate reads the hosts the mac "
                 f"lane launches — {stands_for} — and a host it cannot find is a "
                 f"refusal, never a skip.")
            continue
        path, origin = os.path.realpath(found), f"`{what}` on PATH -> {found}"
    st, why = stamp(path)
    if st is None:
        fail(f"{name} ({side} side): {path} {why}. Resolved from {origin}; it stands "
             f"for {stands_for}.")
        continue
    plat, minos, sdk, which = st
    reads += 1
    seen = "modern" if sdk >= MODERN_FLOOR else "compat"
    measured[seen].append((name, show(sdk)))
    print(f"check-design-generation: {name:9s} {seen:6s} sdk {show(sdk):8s} "
          f"minos {show(minos):8s} platform {plat} {which}  <- {origin}")

    if plat != PLATFORM_MACOS:
        fail(f"{name}: {path} is stamped for platform {plat}, not macOS "
             f"({PLATFORM_MACOS}) — the generation SwiftUI picks is a macOS fact "
             f"and this read cannot speak to it")
    if seen != side:
        if side == "modern":
            fail(f"{name}: measured sdk {show(sdk)} ({which}, minos {show(minos)}) at "
                 f"{path}, but the table declares it MODERN, which needs sdk >= "
                 f"{floor_of(MODERN_FLOOR)}. A host stamped below that runs "
                 f"SwiftUI's COMPATIBILITY generation. This leg stands for "
                 f"{stands_for} — so the flake's `buildInputs = [ pkgs.apple-sdk_26 ]` "
                 f"is the line to look at (this gate normalised DEVELOPER_DIR to "
                 f"{flake_sdk} from mkShell's own buildInputs).")
        else:
            fail(f"{name}: measured sdk {show(sdk)} ({which}, minos {show(minos)}) at "
                 f"{path}, but the table declares it COMPAT, which needs sdk < "
                 f"{floor_of(MODERN_FLOOR)}. This host has moved to the MODERN "
                 f"generation — it stands for {stands_for}, and kaya does not link it, "
                 f"so a vendor or nixpkgs rebuild moved it, not a kaya commit. The "
                 f"ledger's standing constraint (docs/deferred.md) requires the compat "
                 f"generation to keep a leg: it is where the Button measurement bug "
                 f"class lives (docs/traps.md). Move this leg's side in the table only "
                 f"with a compat leg left standing.")
    floor = rules.get("minos_below")
    if floor is not None and minos >= floor:
        fail(f"{name}: measured minos {show(minos)} ({which}) at {path}, and the "
             f"MODERN half requires minos < {floor_of(floor)} — the deployment floor "
             f"of kaya-built guests rose, so they no longer launch on any macOS "
             f"older than {show(minos)}. flake.nix omits darwinMinVersionHook on "
             f"purpose (the sdk field alone buys the design generation), so look for "
             f"that hook arriving in the flake, or for MACOSX_DEPLOYMENT_TARGET being "
             f"set outside it. This gate cannot tell those two apart from a stamp; "
             f"what it can see is that it inherited MACOSX_DEPLOYMENT_TARGET="
             f"{os.environ.get('MACOSX_DEPLOYMENT_TARGET', '<unset>')}.")

    # The probe legs the gate compiled itself have a second witness: the
    # store path the SDK came from names its version. If the compile did
    # not honour the DEVELOPER_DIR this gate normalised, these disagree
    # and the measurement is not of the thing it was aimed at. Skipped
    # for a substituted leg, whose binary this gate did not build.
    if name == "flake-cc" and name not in SUBST:
        declared_sdk = re.search(r"apple-sdk-([0-9]+(?:\.[0-9]+)*)", flake_sdk)
        if declared_sdk is None:
            fail(f"the SDK store path {flake_sdk} carries no version to cross-check "
                 f"the probe against")
        else:
            want = tuple(int(p) for p in declared_sdk.group(1).split("."))[:2]
            if sdk[:len(want)] != want:
                fail(f"{name}: the shell declares {flake_sdk} but the probe it "
                     f"compiled stamps sdk {show(sdk)} — the compile did not honour "
                     f"the DEVELOPER_DIR this gate set, so the number above is not a "
                     f"measurement of the flake's SDK")

# ------------------------------------------------------------ the verdict

for side in ("modern", "compat"):
    if not measured[side]:
        fail(f"the {side.upper()} half of the table is EMPTY — no leg measured on that "
             f"side. The mac lane must exercise BOTH macOS design generations "
             f"(docs/deferred.md's standing constraint); a lane running one of them is "
             f"a lane that cannot see the other's bug classes.")

if reads != DECLARED_READS:
    fail(f"REFUSING A VERDICT: declared {DECLARED_READS} reads, made {reads}. The "
         f"findings above say which leg went unread; a sweep that reads fewer stamps "
         f"than it declared cannot report on a table it did not finish.")

if status == 0:
    print("check-design-generation: OK ({}/{} reads — modern: {}; compat: {})".format(
        reads, DECLARED_READS,
        ", ".join(f"{n} sdk {v}" for n, v in measured["modern"]),
        ", ".join(f"{n} sdk {v}" for n, v in measured["compat"])))
else:
    print("check-design-generation: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)
PY
status=$?
exit "$status"

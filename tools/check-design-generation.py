#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# EVERY MAC LEG STARTS IN A MAIN EXECUTABLE STAMPED FOR macOS 26's MODERN
# DESIGN GENERATION (the maintainer, 2026-10-25: "drop the old look
# everywhere"; docs/gates.md). It measures COMPILES, never target/: the two
# probes and the four hosts (tools/mac/kaya-host.c) are built here, through
# the lane's own build_hosts, and the lane's argv table is read for which
# executable each language starts in. The lane's runtime half of the wall is
# tools/lib/lanes/mac.py require_modern.
#
# ENV HYGIENE: `env -u DEVELOPER_DIR -u SDKROOT cc` drops the flake's SDK
# and stamps 14.4 (docs/chrome/sdk-bump-scout.md); the probe compile is
# normalised from mkShell's own `buildInputs` instead.
#
# TEST-ONLY SEAM: KAYA_DESIGN_GEN_SUBST="name=path,…" replaces the binary a
# named read takes. An unrecognised name is a hard failure.

import os
import platform as platform_mod
import re
import subprocess

import macho
from lanes import mac as lane

if platform_mod.system() != "Darwin":
    print(f"check-design-generation: this gate reads macOS Mach-O stamps and builds probes "
          f"with the mac toolchain; it has nothing to say on {platform_mod.system()}. "
          f"Refusing rather than passing.", file=sys.stderr)
    sys.exit(1)

declared = os.environ.get("buildInputs", "")
sdks = [p for p in declared.split() if re.search(r"apple-sdk-[0-9][^/]*$", p.rstrip("/"))]
if len(sdks) != 1:
    print(f"check-design-generation: mkShell exported buildInputs={declared!r}, which names "
          f"{len(sdks)} apple-sdk path(s) — this gate needs exactly 1 to know which SDK the "
          f"shell links against. flake.nix's `buildInputs = [ pkgs.apple-sdk_26 ];` is what "
          f"puts it there (docs/chrome/sdk-bump-scout.md §2).", file=sys.stderr)
    sys.exit(1)
flake_sdk = sdks[0].rstrip("/")

DECLARED_READS = 2 + len(lane.HOSTS)
status = 0


def fail(msg):
    global status
    print(f"check-design-generation: {msg}", file=sys.stderr)
    status = 1


SUBST = {}
for item in os.environ.get("KAYA_DESIGN_GEN_SUBST", "").split(","):
    if not item.strip():
        continue
    name, sep, path = item.partition("=")
    if not sep:
        fail(f"KAYA_DESIGN_GEN_SUBST entry {item!r} is not name=path")
        continue
    SUBST[name.strip()] = path.strip()

with scratch_dir("check-design-generation-") as tmp:
    (tmp / "probe.c").write_text("int main(void) { return 0; }\n", encoding="utf-8")
    cc_env = dict(os.environ, DEVELOPER_DIR=flake_sdk,
                  SDKROOT=f"{flake_sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
    cc = subprocess.run(["cc", str(tmp / "probe.c"), "-o", str(tmp / "probe-flake-cc")],
                        env=cc_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                        text=True, encoding="utf-8", check=False)
    if cc.returncode != 0:
        print(f"check-design-generation: the flake-linked C probe did not compile with "
              f"DEVELOPER_DIR={flake_sdk}:", file=sys.stderr)
        sys.stderr.write(cc.stderr)
        sys.exit(1)

    (tmp / "probe.swift").write_text('print("kaya design-generation probe")\n', encoding="utf-8")
    swift_env = {k: v for k, v in os.environ.items() if k not in ("SWIFTC", "SWIFT_DEVELOPER_DIR")}
    swiftc = subprocess.run(
        ["bash", "-c", 'source "$1/tools/lib/swift-toolchain.sh" && kaya_swiftc "$2" -o "$3"',
         "swift-toolchain", str(ROOT), str(tmp / "probe.swift"), str(tmp / "probe-swift")],
        env=swift_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        encoding="utf-8", check=False)
    if swiftc.returncode != 0:
        print("check-design-generation: the swift probe did not compile through kaya_swiftc "
              "(tools/lib/swift-toolchain.sh):", file=sys.stderr)
        sys.stderr.write(swiftc.stderr)
        sys.exit(1)

    hosts = tmp / "hosts"
    if lane.build_hosts(ROOT, out_dir=hosts, log=tmp / "hosts.log") != 0:
        print("check-design-generation: build_hosts (tools/lib/lanes/mac.py) failed:",
              file=sys.stderr)
        sys.stderr.write((tmp / "hosts.log").read_text(encoding="utf-8", errors="replace"))
        sys.exit(1)

    READS = [
        ("flake-cc", str(tmp / "probe-flake-cc"),
         "the rust, go, c, ocaml and haskell legs, linked by this shell's cc"),
        ("swift", str(tmp / "probe-swift"),
         "the swift legs and the SwiftUI interpreter, built through kaya_swiftc"),
        *((lane.HOSTS[lang], str(hosts / lane.HOSTS[lang]), f"the {lang} legs' host")
          for lang in lane.HOSTS),
    ]
    known = {name for name, _path, _what in READS}
    for name in sorted(set(SUBST) - known):
        fail(f"KAYA_DESIGN_GEN_SUBST names {name!r}, which is not a read here "
             f"({', '.join(sorted(known))}); a substitution that lands nowhere makes its "
             f"negative test vacuous")

    reads = 0
    for name, path, what in READS:
        if name in SUBST:
            path = SUBST[name]
            print(f"check-design-generation: SUBSTITUTED {name} -> {path} (test-only seam)")
        st, why = macho.stamp(path)
        if st is None:
            fail(f"{name}: {path} {why}; it stands for {what}")
            continue
        plat, minos, sdk, which = st
        reads += 1
        print(f"check-design-generation: {name:12s} sdk {macho.show(sdk):8s} minos "
              f"{macho.show(minos):8s} platform {plat} {which}")
        if plat != macho.PLATFORM_MACOS or sdk < macho.MODERN_FLOOR:
            fail(f"{name}: measured platform {plat} sdk {macho.show(sdk)} ({which}) at {path}; "
                 f"it stands for {what}, and below sdk {macho.floor_of(macho.MODERN_FLOOR)} "
                 f"macOS draws the old (compatibility) design generation. The flake's "
                 f"`buildInputs = [ pkgs.apple-sdk_26 ]` is the SDK this shell links with.")
        if name == "flake-cc" and name not in SUBST:
            if minos >= macho.MODERN_FLOOR:
                fail(f"flake-cc: minos {macho.show(minos)} — the deployment floor of kaya-built "
                     f"guests rose to the SDK's; flake.nix omits darwinMinVersionHook on purpose. "
                     f"Inherited MACOSX_DEPLOYMENT_TARGET="
                     f"{os.environ.get('MACOSX_DEPLOYMENT_TARGET', '<unset>')}")
            declared_sdk = re.search(r"apple-sdk-([0-9]+(?:\.[0-9]+)*)", flake_sdk)
            want = (tuple(int(p) for p in declared_sdk.group(1).split("."))[:2]
                    if declared_sdk else None)
            if want is None or sdk[:len(want)] != want:
                fail(f"flake-cc: the shell declares {flake_sdk} but the probe stamps sdk "
                     f"{macho.show(sdk)}, so the compile did not honour the SDK this gate set")

    # THE WALL'S SENTENCE, made to print: a vendor host stamped below the floor.
    vendor = pathlib.Path(subprocess.run(
        ["python3", "-c", "import sys, sysconfig; print(sysconfig.get_config_var('BINDIR') "
         "+ '/python%d.%d' % sys.version_info[:2])"], capture_output=True, text=True,
        encoding="utf-8", check=False).stdout.strip())
    vst, _ = macho.stamp(vendor)
    if vst is not None and vst[2] < macho.MODERN_FLOOR:
        said = lane.modern_refusal(vendor, "python")
        if not said or lane.host_path("python") not in said:
            fail(f"require_modern's refusal for {vendor} (sdk {macho.show(vst[2])}) said {said!r}; "
                 f"it must refuse and name {lane.host_path('python')}")
    if lane.modern_refusal(tmp / "probe-flake-cc", "c") is not None:
        fail("require_modern refused the flake-linked probe, which is stamped modern")

# THE ROUTES: every language's leg starts in a path the lane built or staged,
# and the four hosted languages in their host.
for lang in (*lane.LANGS, "c"):
    exe = lane._guest_argv("milestone2", lang, lambda stem: f"dist-newstyle/{stem}",
                           "milestone2")[0]
    if "/" not in exe:
        fail(f"the {lang} legs start in `{exe}`, a name resolved off PATH: a vendor host, "
             f"stamped by whoever built it. They start in {lane.HOSTS_DIR}/ "
             f"(tools/mac/kaya-host.c) "
             f"or in a binary this lane links.")
    elif lang in lane.HOSTS and exe != lane.host_path(lang):
        fail(f"the {lang} legs start in {exe}, not {lane.host_path(lang)}")

if reads != DECLARED_READS:
    fail(f"REFUSING A VERDICT: declared {DECLARED_READS} reads, made {reads}")

if status == 0:
    print(f"check-design-generation: OK ({reads}/{DECLARED_READS} reads modern; "
          f"{len(lane.LANGS) + 1} languages routed through built executables)")
else:
    print("check-design-generation: FINDINGS ABOVE", file=sys.stderr)
sys.exit(status)

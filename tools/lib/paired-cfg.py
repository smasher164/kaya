"""A platform-gated core surface must be gated for BOTH platforms.

The picked-file redemption path shipped `#[cfg(unix)]` end to end —
PathSource, PickedOpen, PickedFile::open, and a PickedSource::open
returning a POSIX fd — so on Windows there was no way to redeem a picked
handle at all. The design's central claim, that kaya hands over a
capability the guest opens with its own file API, simply had no Windows
expression.

It passed every gate. check-targets cross-compiles the WinUI backend and
was perfectly happy, because the only thing that would have referenced
PathSource on Windows was the file-dialog apply arm, and that arm was a
depth stub. A cfg'd-out surface whose only cfg'd-in consumer is also
cfg'd out is invisible to a compiler: nothing is missing until something
asks for it.

So the rule is structural instead. In the CORE — the platform-neutral
layer every backend and binding sits on — an item gated to one platform
must have a counterpart gated to the other. The counterpart may be a
stub that returns an error; what it may not be is absent, because absent
is what reads as fine right up until a backend needs it.

The backends themselves are exempt: gtk.rs IS linux and winui/mod.rs IS
windows, so a one-sided gate there says something true.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# The platform-neutral layer. Not the backends, which are one platform
# each by construction.
CORE = [
    "crates/kaya/src/protocol.rs",
    "crates/kaya/src/capi.rs",
    "crates/kaya/src/app.rs",
    "crates/kaya/src/scene.rs",
    "crates/kaya/src/wire.rs",
]

# `#[cfg(unix)]` / `#[cfg(windows)]` immediately above an item, and the
# item's name. Attributes and doc comments may sit between.
GATE = re.compile(
    r"#\[cfg\((unix|windows)\)\]\s*"
    r"((?:\s*(?://[^\n]*|#\[[^\]]*\])\n)*)"
    r"\s*(?:pub(?:\([^)]*\))?\s+)?(?:unsafe\s+)?"
    r"(?:fn|struct|enum|impl|trait|type|const|mod)\s+"
    r"(?:<[^>]*>\s*)?([A-Za-z_][A-Za-z0-9_]*)"
)


def gated(text: str) -> dict[str, set[str]]:
    """{item name: {platforms it is gated for}}"""
    out: dict[str, set[str]] = {}
    for platform, _, name in GATE.findall(text):
        out.setdefault(name, set()).add(platform)
    return out


def main() -> int:
    status = 0
    checked = 0
    for name in CORE:
        path = ROOT / name
        if not path.exists():
            print(f"paired-cfg: {name} is missing", file=sys.stderr)
            return 1
        items = gated(path.read_text())
        checked += 1
        for item, platforms in sorted(items.items()):
            if platforms == {"unix", "windows"}:
                continue
            only = next(iter(platforms))
            other = "windows" if only == "unix" else "unix"
            print(
                f"paired-cfg: {name} gates `{item}` to {only} with no {other} "
                f"counterpart. A core surface that exists on one platform "
                f"only is invisible until a backend needs it — which is how "
                f"the picked-file redemption path shipped unix-only. Give it "
                f"a {other} arm, even one that returns an error.",
                file=sys.stderr,
            )
            status = 1

    if checked < len(CORE):
        print("paired-cfg: not every core file was read", file=sys.stderr)
        return 1

    # The gate guards itself, both directions.
    lone = gated("#[cfg(unix)]\nfn only_here() {}\n")
    both = gated("#[cfg(unix)]\nfn f() {}\n#[cfg(windows)]\nfn f() {}\n")
    if lone.get("only_here") != {"unix"} or both.get("f") != {"unix", "windows"}:
        print("paired-cfg: SELF-TEST FAIL", file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())

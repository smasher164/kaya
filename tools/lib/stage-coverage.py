"""Every backend Stage impl names every required trait method.

THE COMPILER ALREADY DOES THIS for the backends check-targets can
compile; GTK is not one of them, because gtk-sys needs the distro's
pkg-config world (CLAUDE.md). So this reads the trait and the impls as
TEXT: weaker than compiling — it cannot see a wrong signature — but it
costs no docker and catches a method added to the trait and missed in
one backend. check-gtk still compiles the real thing.
"""

import pathlib
import re
import sys

TRAIT = "crates/kaya/src/harness.rs"
IMPLS = [
    ("crates/kaya/src/gtk.rs", "impl crate::harness::Stage for GtkStage {"),
    ("crates/kaya/src/winui/mod.rs", "impl crate::harness::Stage for WinUiStage {"),
]

# A REQUIRED method's signature ends in `;` — one with a default body
# ends in `{`, and a backend may legitimately inherit that.
REQUIRED = re.compile(r"^\s{4}fn\s+(\w+)\s*\(.*?;\s*$", re.S)


def trait_methods(text: str) -> list[str]:
    start = text.index("trait Stage")
    depth, i = 0, text.index("{", start)
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                break
    body = text[i : j + 1]
    # Join wrapped signatures before matching: a long `fn` spills over
    # several lines and only the last one carries the `;`.
    joined, buf = [], ""
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("//") or not stripped:
            continue
        buf = (buf + " " + line) if buf else line
        if stripped.endswith((";", "{", "}")):
            joined.append(re.sub(r"\s+", " ", buf).replace("    fn", "    fn", 1))
            buf = ""
    out = []
    for sig in joined:
        m = re.match(r"^\s*fn\s+(\w+)\s*\(.*;\s*$", sig)
        if m:
            out.append(m.group(1))
    return out


def impl_methods(text: str, anchor: str) -> set[str]:
    start = text.index(anchor)
    depth, i = 0, text.index("{", start)
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                break
    return set(re.findall(r"\bfn\s+(\w+)\s*\(", text[i : j + 1]))


def main() -> int:
    trait_text = pathlib.Path(TRAIT).read_text()
    required = trait_methods(trait_text)
    if len(required) < 20:
        print(
            f"stage-coverage: only parsed {len(required)} required Stage "
            f"methods — the trait's shape moved and this gate went vacuous",
            file=sys.stderr,
        )
        return 1

    status = 0
    for name, anchor in IMPLS:
        path = pathlib.Path(name)
        if not path.exists():
            print(f"stage-coverage: {name} is missing", file=sys.stderr)
            return 1
        have = impl_methods(path.read_text(), anchor)
        for method in required:
            if method not in have:
                print(
                    f"stage-coverage: {name} does not implement Stage::{method} "
                    f"— the trait requires it (no default body)",
                    file=sys.stderr,
                )
                status = 1

    # The gate guards itself: dropping a method from a synthetic impl
    # must be caught.
    sample = "impl crate::harness::Stage for X {\n    fn a(&self) {}\n}"
    if "b" in impl_methods(sample, "impl crate::harness::Stage for X {"):
        print("stage-coverage: SELF-TEST FAIL (bad sample passed)", file=sys.stderr)
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())

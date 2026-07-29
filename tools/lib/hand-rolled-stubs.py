"""No backend may REFUSE a feature in its own words.

check-stubs pairs a runner's wired legs against the backends that still
stub the scene, and check-steps stops demanding legs where a stub
stands. Both read the CALL `depth_stub("<scene>")` (Kotlin:
`depthStub`), because the convention used to be a free-form sentence —
"<scene> is not yet materialized" — and in four milestones not one
backend ever wrote it. check-stubs could therefore only ever pass, and
the filedialog depth slice went straight through it while three
backends refused in three different sentences of their own.

So the sentence itself is now the failure: a refusal that does not go
through the helper is invisible to both gates, and being invisible is
the whole defect.

A REFUSAL IS NOT A SENTINEL. Returning "<the GTK accessibility read is
not implemented yet>" as a value is a different and equally honest
pattern: it cannot equal a valid `<role>/<label>`, so a scene asserting
on it fails loudly with the string in hand. That is a value a comparison
consumes, not a control-flow refusal, and no gate needs to model it. Only
constructs that ABORT are checked here.
"""

import pathlib
import re
import sys

BACKENDS = [
    "crates/kaya/src/gtk.rs",
    "crates/kaya/src/winui/mod.rs",
    "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt",
    "swift/KayaSwiftUI.swift",
]

# Control flow that gives up, across the three languages.
REFUSAL = re.compile(r"(unimplemented!|todo!\(|panic!\(|fatalError\(|\berror\()")

# "We have not built this yet", in the spellings a person reaches for.
# Deliberately broad: a false positive costs one call to the helper, a
# false negative costs a whole matrix run to discover.
SMELL = re.compile(
    r"""(unimplemented!
        |todo!\(
        |not\ implemented
        |not\ yet\ implemented
        |not\ yet\ materialized
        |isn't\ implemented
        |is\ not\ supported\ yet
        |not\ supported\ yet)""",
    re.I | re.X,
)

# A refusal's message can wrap; and the helper's own definition sits
# just above its body. Both need a few lines of context either way.
AFTER = 3
BEFORE = 3


def offenders(text: str) -> list[tuple[int, str]]:
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith(("//", "///", "*", "#")):
            continue
        if not REFUSAL.search(line):
            continue
        window = "\n".join(lines[max(0, i - BEFORE) : i + AFTER + 1])
        if not SMELL.search(window):
            continue
        # The helper itself, and anything already routed through it.
        if "epth_stub" in window or "epthStub" in window:
            continue
        out.append((i + 1, line.strip()))
    return out


def main() -> int:
    bad = 0
    for name in BACKENDS:
        path = pathlib.Path(name)
        if not path.exists():
            print(f"hand-rolled-stubs: {name} is missing", file=sys.stderr)
            return 1
        for n, line in offenders(path.read_text()):
            print(
                f"check-stubs: {name}:{n} refuses in its own words, where "
                f"neither check-stubs nor check-steps can see it — route "
                f'depth stubs through depth_stub("<scene>"):\n'
                f"    {line}",
                file=sys.stderr,
            )
            bad += 1
    if bad:
        return 1

    # The guard guards itself, both directions: a hand-rolled refusal is
    # caught, the same thing routed through the helper is not, and a
    # sentinel VALUE saying the same words is not a refusal at all.
    caught = offenders('    panic!("kaya: menus are not implemented here");')
    routed = offenders('    crate::depth_stub("menus");')
    prefixed = offenders('    kayaDepthStub("menus")')
    sentinel = offenders('    "<the read is not implemented yet>".to_owned()')
    if not caught or routed or prefixed or sentinel:
        print("check-stubs: SELF-TEST FAIL (hand-rolled detector)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

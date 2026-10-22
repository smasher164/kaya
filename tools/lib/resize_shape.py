"""The resize verb's shape wait and the choice reader's server reading
(docs/traps.md, the hit test that outran the resize)."""

import re

from kaya_gate import ROOT

SWIFT = "swift/KayaSwiftUI.swift"


def swift_fn(text, name):
    """The FIRST `func name(` body, brace-balanced: kayaChoiceRead has a
    macOS and an iOS definition and the macOS one comes first."""
    hits = list(re.finditer(r"^\s*func " + re.escape(name) + r"\(", text, re.M))
    if not hits:
        return None
    start = text.index("{", hits[0].end())
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[hits[0].start():i + 1]
    return None


# label, (kind, owner), needle the owner holds, needle it may not hold, the
# text that plants the forbidden needle (None for a "holds" route)
ROUTES = (
    ("the resize arm awaits the server's shape after the content size",
     ("arm", "resize_window"), "kayaDiag(kayaAwaitResizeShape(window, before: before))", None, None),
    ("the resize arm reads the frame before it resizes",
     ("arm", "resize_window"), "let before = window.frame", None, None),
    ("the choice reader asks the server about the centre",
     ("fn", "kayaChoiceRead"), "let serverAt = kayaServerHolds(window, NSPoint(x: rect.midX, y: rect.midY))",
     None, None),
    ("the choice refusal says whether this window's shape covers the centre",
     ("fn", "kayaChoiceRead"), '(serverAt.ours ? "covers" : "does not cover") + " the centre, "', None, None),
    ("the choice refusal names the windows above the centre",
     ("fn", "kayaChoiceRead"), 'serverAt.above.joined(separator: " over ")', None, None),
    ("the choice refusal names the hit's pid and the element asked",
     ("fn", "kayaChoiceRead"),
     "asked of this application's element (pid \\(getpid())), the hit belongs to pid \\(hitPid)",
     None, None),
    ("the server reader asks the window server's own hit test",
     ("fn", "kayaServerHit"), "NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)",
     None, None),
    ("the walk steps down the z-order to this window",
     ("fn", "kayaServerHolds"), "below = hit.number", None, None),
    ("the wait polls the server's hit test",
     ("fn", "kayaAwaitResizeShape"), "let hit = read(corner)", None, None),
    ("the wait never settles on the server's bounds",
     ("fn", "kayaAwaitResizeShape"), None, "kayaServerBounds(number) ==",
     '    _ = kayaServerBounds(number) == ""\n'),
)


def findings(text, arm_reader):
    for label, (kind, name), must, must_not, _plant in ROUTES:
        body = arm_reader(text, name) if kind == "arm" else swift_fn(text, name)
        if body is None:
            yield f"resize shape: no `{name}` to read for '{label}'"
            continue
        if must is not None and must not in body:
            yield f"resize shape: {label} — `{name}` no longer holds {must!r}"
        if must_not is not None and must_not in body:
            yield f"resize shape: {label} — `{name}` holds {must_not!r}"


def run(g, arm_reader):
    text = (ROOT / SWIFT).read_text(encoding="utf-8")
    g.counted("resize shape routes", ROUTES, floor=10)
    bad = list(findings(text, arm_reader))
    for line in bad:
        g.finding(line)
    watched = 0
    for label, (kind, name), must, must_not, plant in ROUTES:
        if must is not None:
            cut = g.doctor("resize shape " + label, text, re.escape(must), "removed_route")
        else:
            body = swift_fn(text, name)
            cut = g.doctor("resize shape " + label, text, re.escape(body),
                           lambda m, body=body, plant=plant: body[:-1] + plant + "}")
        g.negative("resize shape " + label,
                   lambda cut=cut: list(findings(cut, arm_reader)), want=label)
        watched += 1
    gone = g.doctor("resize shape missing reader", text,
                    re.escape("func kayaServerHit("), "func kayaServerHitGone(")
    g.negative("resize shape missing reader",
               lambda: list(findings(gone, arm_reader)), want="no `kayaServerHit` to read")
    watched += 1
    g.counted("resize shape watched negatives", watched, floor=len(ROUTES) + 1)
    return 1 if bad else 0

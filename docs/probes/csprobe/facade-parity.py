#!/usr/bin/env python3
"""C#'s template zone has TWO surfaces; hold them level.

`sealed class Tpl` (bindings/csharp/KayaApp.cs) is the zone. The
generated `{Rec}Row` (guests/csharp/*Kaya.cs, emitted by
tools/kaya-csgen) is the `foreach (var row in c.Rows())` façade over it
and forwards the zone one member at a time, by hand — under a doc that
says in as many words "the forwarders below are the ZONE and not a
selection from it". It was a selection: `SetGrow` sat on the zone and
not on the façade for a milestone, so a per-row grow was reachable
through `tx.Each` and not through `foreach`, which is the exact
difference the sugar pass's S4b says no guest should have to know about.

tpl-surfaces.py already holds Rust's `Tpl`/`Row` pair level (its own
comment explains why: a hand-forwarded list drifts). This is that clause
for C#, and it is the only other binding with the same shape.

Usage: facade-parity.py [<repo root>]   Exit 0 level, 1 with the gap.
"""

import os
import re
import sys

# OFF THE FAÇADE BY THE FAÇADE'S OWN WRITTEN RULE (the generated doc
# names them): a row surface hands out sugar, and its Tpl is private, so
# the zone's plumbing is reached by opening the For yourself.
PLUMBING = {
    "Widget", "BindTextElement", "BindTextField", "BindCheckedField",
    "BindSourceField", "BindValueField", "AddChild", "ContextMenu",
    "Collection", "Each", "ForEach", "When",
}


def brace_block(src, header_re):
    m = re.search(header_re, src, re.M)
    if not m:
        return None
    i = src.find("{", m.start())
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
    return None


def split_params(params):
    """Top-level commas only — a delegate type carries its own."""
    out, depth, cur = [], 0, ""
    for ch in params:
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def norm(params):
    """A parameter list as TYPES alone, spelled one way.

    The façade is generated with fully qualified delegate types
    (System.Action<…, System.Collections.Generic.List<object>, …>) while
    the zone is hand-written against the file's usings, and the
    parameter NAMES are free to differ. Comparing unqualified types is
    the claim that matters: the same call compiles against both.
    """
    out = []
    for p in split_params(params):
        p = " ".join(p.split())
        if not p:
            continue
        p = p.replace("System.Collections.Generic.", "").replace("System.", "")
        p = re.sub(r"\s*=\s*[^,]+$", "", p)          # drop the default
        p = re.sub(r"^params\s+", "", p)
        out.append(p.rsplit(" ", 1)[0])              # drop the name
    return "(" + ", ".join(out) + ")"


def members(body):
    return {
        (m.group(1), norm(m.group(2)))
        for m in re.finditer(r"^    public\s+[\w<>\[\]]+\s+(\w+)\(([^)]*)\)", body, re.M)
    }


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    app = open(os.path.join(root, "bindings/csharp/KayaApp.cs"), encoding="utf-8").read()
    zone_body = brace_block(app, r"^sealed class Tpl\b")
    if zone_body is None:
        print("facade-parity: cannot find `sealed class Tpl` — fix this reader, "
              "do not delete it")
        return 1
    zone = {(n, p) for (n, p) in members(zone_body) if n not in PLUMBING}
    # THE READER IS WATCHED: a census that reads nothing agrees with
    # everything.
    if len(zone) < 20:
        print(f"facade-parity: read only {len(zone)} public members out of Tpl — "
              "this reader has stopped seeing the zone it exists to compare")
        return 1

    status, seen = 0, 0
    gdir = os.path.join(root, "guests/csharp")
    for fn in sorted(os.listdir(gdir)):
        if not fn.endswith("Kaya.cs"):
            continue
        src = open(os.path.join(gdir, fn), encoding="utf-8").read()
        for rec in re.findall(r"^sealed class (\w+)Row\b", src, re.M):
            body = brace_block(src, rf"^sealed class {rec}Row\b")
            seen += 1
            gap = sorted(zone - members(body))
            if gap:
                status = 1
                print(
                    f"facade-parity: guests/csharp/{fn}'s {rec}Row does not forward "
                    + ", ".join(f"{n}{p}" for n, p in gap)
                    + " — the row façade is generated from a hand-written list in "
                    "tools/kaya-csgen/Program.cs, and a member on the zone and not "
                    "on the façade is reachable through tx.Each and not through "
                    "`foreach (var row in c.Rows())`. Add the forward there and "
                    "regenerate, or name it in this gate's PLUMBING with a reason."
                )
    if seen == 0:
        print("facade-parity: found no generated {Rec}Row surface to compare — "
              "the reader has gone blind rather than the tree gone clean")
        return 1
    return status


if __name__ == "__main__":
    sys.exit(main())

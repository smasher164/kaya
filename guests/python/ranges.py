"""The text-ranges conformance scene, Python port: the three primitives
an editor cannot write for itself — HIGHLIGHT a set of ranges, SELECT
one, REVEAL one — driven by a search this file writes in six lines.

THE SIX LINES ARE THE POINT. kaya ships no find engine, no find bar and
no regex dialect (docs/ranges-plan.md §3): what to decorate is the app's
question, and every editor answers it differently. What no app can write
for itself is the other half — colouring a run of a native text view,
moving its selection, scrolling it into view — and that is exactly what
the framework ships.

THE OFFSETS ARE UTF-8 BYTE OFFSETS, AND THAT IS WHY THIS SEARCH RUNS
OVER `doc.encode()` RATHER THAN OVER `doc`. Python is one of the four
languages whose own string index is NOT kaya's unit: `str.find` counts
scalars, so on this document `doc.find("alpha")` answers 51 where kaya's
offset is 57. The document opens with a CJK word for exactly that
reason — the six-byte gap is a unit test, and a guest (or a backend)
that mixed the two would decorate six characters early and the scene's
frozen offsets would say so. Searching the bytes is not a workaround: it
is the honest spelling of "give kaya the offsets it asked for", it costs
one `.encode()`, and UTF-8 is self-synchronizing, so a byte-level match
lands on a character boundary and finds the same occurrences a `str`
search would.

WHAT EACH LEG PROVES, in the order the script runs them:
  * a set of three matches decorated at once, read back out of the
    platform's own accessibility tree;
  * one of them selected, likewise;
  * the third REVEALED — asserted `offscreen` first, so the leg cannot
    pass on a document that happened to fit;
  * a user's keystroke DROPPING the declared set (D2: ranges are
    app-owned and never tracked across an edit);
  * a `select_range` REFUSED because the user is mid-composition (D4),
    which is the one thing on this surface a backend is expected not to
    do.

Canonical semantics in guests/rust/ranges.rs; the byte-frozen contract
in tools/scenes/ranges.steps.
"""

import sys

import kaya

app = kaya.App()

# The document, frozen — byte-identical to guests/rust/ranges.rs's DOC,
# because invariant 6 compares every assertion byte for byte across the
# languages and the offsets below are positions in THESE bytes. Three
# occurrences of `alpha` and nothing else containing that substring;
# forty short lines, so the last match is far below a 240x96 viewport
# and REVEAL has something to do.
DOC = """line 00: 日本語 preface
line 01: gamma kappa
line 02: alpha beta gamma
line 03: epsilon theta
line 04: zeta nu
line 05: eta zeta
line 06: theta lambda
line 07: iota delta
line 08: kappa iota
line 09: alpha eta theta
line 10: mu eta
line 11: nu mu
line 12: beta epsilon
line 13: gamma kappa
line 14: delta gamma
line 15: epsilon theta
line 16: zeta nu
line 17: eta zeta
line 18: theta lambda
line 19: iota delta
line 20: kappa iota
line 21: lambda beta
line 22: mu eta
line 23: nu mu
line 24: beta epsilon
line 25: gamma kappa
line 26: delta gamma
line 27: epsilon theta
line 28: zeta nu
line 29: eta zeta
line 30: theta lambda
line 31: iota delta
line 32: kappa iota
line 33: lambda beta
line 34: mu eta
line 35: nu mu
line 36: beta epsilon
line 37: alpha iota kappa
line 38: delta gamma
line 39: the last line"""

NEEDLE = "alpha"

# The app's own copy of the document, which is the ONLY authority on
# what the offsets mean. It advances on every edit, exactly as an
# editor's buffer does.
doc = DOC


def find_all(text, needle):
    """THE WHOLE SEARCH. Literal, forward, non-overlapping, over the
    UTF-8 bytes — so what it yields is already kaya's unit. An editor
    that wants case folding, word boundaries or a regex dialect writes
    those here, in the app, where its users can be told what they mean.
    """
    data, hit = text.encode(), needle.encode()
    hits, at = [], data.find(hit)
    while at >= 0:
        hits.append(range(at, at + len(hit)))
        at = data.find(hit, at + len(hit))
    return hits


def on_edit(text):
    # THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO. kaya has already
    # dropped the decorations — a declared set is bound to the text it
    # was declared against — and this is the app agreeing rather than
    # being told: an editor whose document moved has to search again
    # before it can claim anything about where the matches are.
    global doc
    doc = text
    status.set("0 matches")


def on_find():
    hits = find_all(doc, NEEDLE)
    editor.highlight_ranges(hits)
    # The second match, so a leg can tell the selection apart from "the
    # first thing found".
    if len(hits) > 1:
        editor.select_range(hits[1])
    status.set(f"{len(hits)} matches")


def on_reveal_last():
    hits = find_all(doc, NEEDLE)
    if hits:
        editor.reveal_range(hits[-1])


def on_focus_editor():
    editor.focus()


def on_select_first():
    hits = find_all(doc, NEEDLE)
    if hits:
        editor.select_range(hits[0])


with app.window(title="ranges"):
    status = kaya.signal("0 matches")
    with kaya.column():
        # The editor, seeded with the document the app opened. The a11y
        # id is not decoration: every range assertion reads the
        # platform's accessibility tree, and the id is how a leg finds
        # this control there.
        editor = kaya.textarea(on_change=on_edit)          # textarea#0
        editor.a11y_id("doc").a11y_label("Document").set_text(DOC)
        kaya.label(bind=status)                            # label#0
        with kaya.row():
            kaya.button("find", on_click=on_find)                  # button#0
            kaya.button("reveal last", on_click=on_reveal_last)    # button#1
            kaya.button("focus editor", on_click=on_focus_editor)  # button#2
            kaya.button("select first", on_click=on_select_first)  # button#3

sys.exit(app.run())

#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# ONE ID SPACE FOR WIDGETS AND TEMPLATE NODES (DESIGN.md, Binding
# conventions), FOR THE ONE TIER WITH NO ALLOCATOR. Every binding mints
# both from one monotone counter; the C guests hand-author their
# numbers, and crates/kaya/src/scene.rs deliberately keeps `widgets`
# and `template_nodes` as separate maps — so a C guest that re-collides
# the two spaces trips nothing at the core, renders correctly, and
# ships. All eight overlapped until 2026-08-25 (docs/deferred.md, the
# C-floor chore). No lane can see it; this census is the only wall.
#
# HOW IT PARSES, and what it cannot read:
#   * Comments and string/char literals are BLANKED first (line breaks
#     kept, so line numbers stay exact). They carry numbers and even
#     whole call texts — self-test N4 plants one of each.
#   * The create calls are then walked IN SOURCE ORDER against a
#     template-nesting depth: kaya_tx_create_widget's id is a live
#     widget at depth 0 and a template node inside; kaya_tx_create_for
#     and kaya_tx_create_when take their id at the CURRENT depth and
#     then OPEN a template; kaya_tx_template_end closes one. That is
#     scene.rs's own division of the two maps.
#   * NOT the `W_`/`N_` prefixes: feed.c's N_POSTS and reorder.c's
#     N_ITEMS are row COUNTS whose numbers collide with real widget ids
#     in their own files, so a name-keyed census would refuse both
#     guests today.
#   * An id argument must fold to a number — a decimal/hex literal, a
#     #define, or #defines in + - * arithmetic. One that does not is a
#     FINDING naming the site, never a skip: an id this gate cannot
#     read is an id it cannot hold in a space.
#   * Preprocessor conditionals are not evaluated. A template opened on
#     one #if branch and closed on the other reads as unbalanced, which
#     is also a finding.
# Signals, collections, menu items, windows, alerts and dialogs keep
# their own id spaces and are not read here.

import ast
import io
import re
import shutil
import subprocess
import tarfile

g = Gate("check-c-ids")

# The chore's own commit: the eight guests one revision earlier are the
# shipped bug this gate exists for, and self-test N0 runs it.
PRE_REV = "3d94ae3^"

# A census that reads two files agrees with everything. Both floors sit
# well under the tree's real numbers (8 guests, 44 widget ids, 25 node
# ids on 2026-08-26) and exist to catch a walk that went blind, not to
# track the roster.
MIN_GUESTS = 6
MIN_IDS = 40


def strip_c(text):
    """Comments and string/char literals blanked, every newline kept."""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "/*":
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
        elif two == "//":
            j = text.find("\n", i)
            j = n if j == -1 else j
        elif text[i] in "\"'":
            quote = text[i]
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                if text[j] == "\n":  # unterminated; C would not compile
                    break
                j += 1
        else:
            out.append(text[i])
            i += 1
            continue
        out.append("".join(c if c == "\n" else " " for c in text[i:j]))
        i = j
    return "".join(out)


DEFINE = re.compile(
    r"^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)[ \t]+(\S.*?)[ \t]*$", re.M)
CALL = re.compile(
    r"\bkaya_tx_(create_widget|create_for|create_when|template_end)"
    r"\s*\(")
# What puts a guest in the roster: ANY of the three template calls, not
# template_end alone. A guest whose only close was deleted still
# declares a template, and dropping it from the walk would answer that
# with silence (self-test N6).
TEMPLATE_CALL = re.compile(
    r"\bkaya_tx_(create_for|create_when|template_end)\s*\(")


def fold(expr, defines):
    """A C id expression as a number, or None. Literals, #defines and
    + - * over them; anything else is unreadable ON PURPOSE."""
    try:
        tree = ast.parse(expr.strip(), mode="eval")
    except SyntaxError:
        return None

    def value(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            return defines.get(node.id)
        if isinstance(node, ast.UnaryOp) and isinstance(
                node.op, (ast.UAdd, ast.USub)):
            inner = value(node.operand)
            return None if inner is None else (
                inner if isinstance(node.op, ast.UAdd) else -inner)
        if isinstance(node, ast.BinOp) and isinstance(
                node.op, (ast.Add, ast.Sub, ast.Mult)):
            left, right = value(node.left), value(node.right)
            if left is None or right is None:
                return None
            if isinstance(node.op, ast.Add):
                return left + right
            if isinstance(node.op, ast.Sub):
                return left - right
            return left * right
        return None

    return value(tree.body)


def call_args(text, at):
    """Top-level arguments of the call whose '(' is at `at`."""
    depth, i, start, parts = 0, at, at + 1, []
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                parts.append(text[start:i])
                return parts
        elif text[i] == "," and depth == 1:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    return None


def census(root):
    """(stdout lines, stderr lines, failed) for one tree's C guests."""
    findings = []

    def fail(text):
        findings.append("check-c-ids: " + text)

    def read(path):
        """(widgets, nodes) as {id: [(line, spelling, call)]}."""
        code = strip_c(path.read_text(encoding="utf-8", errors="replace"))
        if not TEMPLATE_CALL.search(code):
            return None
        rel = path.relative_to(root)
        defines = {}
        for m in DEFINE.finditer(code):
            got = fold(m.group(2), defines)
            if got is not None:
                defines[m.group(1)] = got
        widgets, nodes = {}, {}
        depth, opened = 0, []
        for m in CALL.finditer(code):
            fn = m.group(1)
            line = code.count("\n", 0, m.start()) + 1
            if fn == "template_end":
                if depth == 0:
                    fail(f"{rel}:{line}: kaya_tx_template_end with no "
                         f"template open — this census walks the calls "
                         f"in source order and can no longer tell a "
                         f"live widget from a template node in this "
                         f"file")
                else:
                    depth -= 1
                    opened.pop()
                continue
            args = call_args(code, m.end() - 1)
            if args is None or len(args) < 2:
                fail(f"{rel}:{line}: kaya_tx_{fn} call whose argument "
                     f"list this census cannot read")
                continue
            spelling = " ".join(args[1].split())
            number = fold(spelling, defines)
            if number is None:
                fail(f"{rel}:{line}: kaya_tx_{fn}'s id {spelling!r} "
                     f"does not fold to a number, so this census cannot "
                     f"hold it in an id space. Spell the id as a "
                     f"#define of a literal (the C floor's own "
                     f"convention) or teach fold() the shape, "
                     f"deliberately")
            else:
                where = nodes if depth else widgets
                where.setdefault(number, []).append(
                    (line, spelling, f"kaya_tx_{fn}"))
            if fn in ("create_for", "create_when"):
                depth += 1
                opened.append(line)
        if depth:
            fail(f"{rel}: {depth} template(s) opened and never closed "
                 f"(first at line {opened[0]}) — "
                 f"kaya_tx_create_for/_create_when without a matching "
                 f"kaya_tx_template_end, so every id after it is filed "
                 f"in the wrong space and this census cannot judge the "
                 f"file")
        return rel, widgets, nodes

    guests = []
    for path in sorted(root.glob("guests/**/*.c")):
        got = read(path)
        if got is not None:
            guests.append(got)

    out = []
    widget_total = sum(len(w) for _, w, _ in guests)
    node_total = sum(len(n) for _, _, n in guests)
    for rel, widgets, nodes in guests:
        out.append(f"check-c-ids:   {rel}: {len(widgets)} widget id(s) "
                   f"{sorted(widgets)}, {len(nodes)} template-node "
                   f"id(s) {sorted(nodes)}")
    out.append(f"check-c-ids: census — {len(guests)} template-declaring "
               f"C guest(s) under guests/, {widget_total} widget id(s), "
               f"{node_total} template-node id(s)")

    if len(guests) < MIN_GUESTS:
        fail(f"census found only {len(guests)} template-declaring C "
             f"guest(s), under the floor of {MIN_GUESTS} — a census "
             f"that reads almost nothing agrees with everything. "
             f"Either the walk over guests/**/*.c broke or the floor "
             f"is stale; do not lower it to match a broken walk")
    if widget_total + node_total < MIN_IDS:
        fail(f"census read only {widget_total + node_total} id(s) in "
             f"all, under the floor of {MIN_IDS} — the call walk is "
             f"finding almost nothing (same reasoning as the guest "
             f"floor above)")

    err = []
    colliding = 0
    for rel, widgets, nodes in guests:
        overlap = sorted(set(widgets) & set(nodes))
        if not overlap:
            continue
        colliding += 1
        ceiling = max(list(widgets) + list(nodes))
        for number in overlap:
            sites = []
            for label, table in (("live widget", widgets),
                                 ("template node", nodes)):
                for line, spelling, call in table[number]:
                    sites.append(f"{label} at {rel}:{line} ({call}, id "
                                 f"spelled {spelling})")
            fail(f"{rel}: id {number} names BOTH a live widget and a "
                 f"template node — " + "; ".join(sites) +
                 f". Continue the widget run instead: the next free "
                 f"number in {rel} is {ceiling + 1}")
    if colliding:
        err.append(f"check-c-ids: {colliding} guest(s) with colliding "
                   f"id spaces")

    err += findings
    # The rule once, under the findings rather than inside each of
    # them: a guest can collide on a dozen numbers at a time (all eight
    # did, until 2026-08-25) and a paragraph repeated a dozen times is
    # a paragraph nobody reads.
    if colliding:
        err.append(
            "check-c-ids: widgets and template nodes share ONE id "
            "space (DESIGN.md, Binding conventions). Every binding "
            "mints both from one monotone counter; the C floor "
            "hand-authors them and must continue the same run. Nothing "
            "else in the tree refuses this — scene.rs keeps `widgets` "
            "and `template_nodes` as separate maps on purpose, so the "
            "collision renders correctly and ships.")
    return out, err, bool(findings)


# --- self-tests: every perturbation on a COPY, count printed ----------
def shadow(name):
    dest = g.scratch() / name
    (dest / "guests").mkdir(parents=True)
    shutil.copytree(ROOT / "guests" / "c", dest / "guests" / "c",
                    symlinks=False)
    return dest


def doctor_file(label, root, rel, pattern, repl):
    p = root / rel
    text = g.doctor(label, p.read_text(encoding="utf-8"), pattern, repl,
                    flags=re.M)
    p.write_text(text, encoding="utf-8")


def combined(root):
    out, err, _failed = census(root)
    return out + err


def refused(root, fragment, label):
    if g.negative(label, lambda: combined(root), want=fragment):
        print(f"check-c-ids: self-test — {label} refused")


# N0 — THE SHIPPED BUG ITSELF. One revision before the C floor learned
# the rule, all eight guests restarted their template-node run at 1
# inside their own widget run. Nothing in the tree refused them; this
# gate must.
n0 = g.scratch() / "n0"
n0.mkdir()
arch = subprocess.run(["git", "archive", PRE_REV, "guests/c"], cwd=ROOT,
                      capture_output=True, check=False)
if arch.returncode != 0:
    print(arch.stderr.decode("utf-8", errors="replace"), file=sys.stderr)
    g.refuse(f"cannot read {PRE_REV} from git — N0's fixture is the "
             f"real pre-fix bytes of all eight guests and there is no "
             f"substitute. Fetch the history (a shallow clone will not "
             f"do) rather than skipping the test.")
# TarFile, not tarfile.open: check-python's encoding rule reads any
# `open(...)` call, and this one is binary by construction.
with tarfile.TarFile(fileobj=io.BytesIO(arch.stdout)) as tf:
    tf.extractall(n0, filter="data")
refused(n0, "8 guest(s) with colliding id spaces",
        f"N0 (the eight guests as of {PRE_REV}, before the C floor "
        f"learned the rule)")

# N1 — a re-collision spelled the way a future author would spell one:
# a #define moved back into the widget run.
s = shadow("n1")
doctor_file("N1 moved todos.c's N_TITLE onto W_FIELD's number", s,
            "guests/c/todos.c", r"^#define N_TITLE 8$",
            "#define N_TITLE 2")
refused(s, "guests/c/todos.c: id 2 names BOTH a live widget and a "
           "template node",
        "N1 (a template node #defined onto a live widget's number)")

# N2 — the same collision as a BARE LITERAL inside the template, which
# no #define census could see. Paired with N4 below, which plants this
# exact call as text.
PLANT = "    kaya_tx_create_widget(&tx, 3, KAYA_KIND_LABEL);"
s = shadow("n2")
doctor_file("N2 planted a literal-id node on W_LIFT's number in "
            "reorder.c", s, "guests/c/reorder.c",
            r"^    kaya_tx_bind_text_element\(&tx, N_TITLE, 0, "
            r"F_TITLE\);$",
            PLANT
            + "\n    kaya_tx_bind_text_element(&tx, N_TITLE, 0, "
              "F_TITLE);")
refused(s, "guests/c/reorder.c: id 3 names BOTH a live widget and a "
           "template node",
        "N2 (a template node created with a bare literal id)")

# N3 — the roster is READ, not remembered. Removing a guest must move
# the count, and a copy-set gutted below the floor must be refused
# rather than agreed with.
s = shadow("n3")
(s / "guests" / "c" / "undo.c").unlink()
before = sum(1 for line in census(ROOT)[0]
             if line.startswith("check-c-ids:   "))
after = sum(1 for line in census(s)[0]
            if line.startswith("check-c-ids:   "))
print(f"check-c-ids: self-test N3 removed one guest from the copy-set: "
      f"roster {before} -> {after}")
if not (before == 8 and after == 7):
    g.refuse(f"SELF-TEST BROKEN (N3 roster {before} -> {after}, "
             f"expected 8 -> 7)")
s = shadow("n3b")
for name in ("undo.c", "todos.c", "menus.c", "milestone2.c"):
    (s / "guests" / "c" / name).unlink()
print("check-c-ids: self-test N3b gutted the copy-set to 4 guests")
refused(s, "under the floor of 6",
        "N3b (a census that reads almost nothing)")

# N4 — THE PARSER READS CODE, NOT TEXT. N2's exact call, planted once
# inside a comment and once inside a string literal in the same
# template. The census must stay GREEN and report the SAME counts.
s = shadow("n4")
doctor_file("N4 planted N2's call inside a comment in reorder.c", s,
            "guests/c/reorder.c",
            r"^    kaya_tx_bind_text_element\(&tx, N_TITLE, 0, "
            r"F_TITLE\);$",
            "    /*" + PLANT + " */"
            + "\n    kaya_tx_bind_text_element(&tx, N_TITLE, 0, "
              "F_TITLE);")
doctor_file("N4 planted N2's call inside a string literal in reorder.c",
            s, "guests/c/reorder.c",
            r'^    kaya_tx_set_text\(&tx, W_LIFT, "lift"\);$',
            f'    kaya_tx_set_text(&tx, W_LIFT, "{PLANT[1:]}");')
n4_out, n4_err, n4_failed = census(s)
if n4_failed:
    print("check-c-ids: SELF-TEST FAIL (N4: a collision that exists "
          "only in a comment and a string was REFUSED — the parser is "
          "reading text):", file=sys.stderr)
    print("\n".join(n4_out + n4_err), file=sys.stderr)
    g.refuse("N4")
if (n4_out, n4_err) != census(ROOT)[:2]:
    print("check-c-ids: SELF-TEST FAIL (N4: commenting-out and quoting "
          "N2's call moved the census's counts, so the blanking pass "
          "is not blanking):", file=sys.stderr)
    print("\n".join(n4_out + n4_err), file=sys.stderr)
    g.refuse("N4")
print("check-c-ids: self-test — N4 (the same call as a comment and as "
      "a string) ignored, counts unmoved")

# N5 — an id this census cannot fold is a finding, not a silent skip.
s = shadow("n5")
doctor_file("N5 gave entry.c a widget id computed at run time", s,
            "guests/c/entry.c",
            r"^    kaya_tx_create_widget\(&tx, W_FIELD, "
            r"KAYA_KIND_ENTRY\);$",
            "    kaya_tx_create_widget(&tx, runtime_id, "
            "KAYA_KIND_ENTRY);")
refused(s, "does not fold to a number",
        "N5 (an id no census can hold in a space)")

# N6 — an unbalanced template: every id after it lands in the wrong
# map, so the census says so instead of judging the file.
s = shadow("n6")
doctor_file("N6 deleted todos.c's only kaya_tx_template_end", s,
            "guests/c/todos.c", r"^    kaya_tx_template_end\(&tx\);$",
            "    /* template_end deleted by self-test N6 */")
refused(s, "opened and never closed", "N6 (a template nothing closes)")

g.negatives_ran(6)

out, err, failed = census(ROOT)
if failed:
    print("\n".join(out + err), file=sys.stderr)
    g.finding("FINDINGS ABOVE")
    raise SystemExit(1)
print("\n".join(out))
g.verdict("no hand-authored C id names both a live widget and a "
          "template node")

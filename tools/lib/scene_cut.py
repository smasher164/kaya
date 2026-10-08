"""The phone-expressible prefix of a shared scene: everything above the
first `cut` verb (or `verb target`, for a verb the scene also uses earlier). One copy for both phone runners AND tools/check-steps.py,
which runs the same census over every lane table's cut in the fast sweep
(docs/traps.md, "A cut refusal only the lane could print", 2026-09-07).

`keep` is a list of verbs the cut may not take with it; `verb=target` holds
one target's assertions and buys the same-verb drop only if `extra`
re-asserts that verb. The two quiet failure modes are refused: a cut verb
the scene no longer has (stale), and a cut that swallows an assertion the
leg exists for."""
import pathlib


class CutRefused(Exception):
    pass


def scene_prefix(path, cut, keep, extra="", who="scene-cut"):
    """Returns (prefix_lines, dropped_lines) over the file's own lines,
    comments removed; raises CutRefused with the sentence the runner
    dies with and the gate reports."""
    path = pathlib.Path(path)
    keeps = keep.split()
    if not keeps:
        raise CutRefused(
            f"{who}: cutting {path} at `{cut}` with no `keep` verb — say "
            f"which assertions this cut may not take with it, or the leg "
            f"can be trimmed until it asserts nothing")
    lines = [line for line in path.read_text(encoding="utf-8").splitlines()
             if not line.lstrip().startswith("#")]
    words = cut.split()
    heads = [line.split()[:len(words)] for line in lines]
    if words not in heads:
        raise CutRefused(
            f"{who}: {path} has no `{cut}` step, so this lane's cut is "
            f"stale — the scene was reshaped and nobody re-read what the "
            f"phone can express. Fix the leg, do not widen the cut.")
    at = heads.index(words)
    prefix, dropped = lines[:at], lines[at:]

    def asserted(seq, verb, target=None):
        return {" ".join(line.split()) for line in seq
                if (p := line.split()) and p[0] == verb
                and (target is None or (len(p) > 1 and p[1] == target))}

    extra_verbs = {(line.split() or [""])[0]
                   for line in extra.replace(";", "\n").splitlines()}
    for tok in keeps:
        verb, _, target = tok.partition("=")
        whole = asserted(lines, verb, target or None)
        kept = asserted(prefix, verb, target or None)
        if not kept:
            raise CutRefused(
                f"{who}: cutting {path} at `{cut}` leaves no `{tok}` step "
                f"at all — the leg would pass without asserting the thing "
                f"it exists for")
        if kept != whole:
            raise CutRefused(
                f"{who}: cutting {path} at `{cut}` drops "
                f"{sorted(whole - kept)} — the cut may not take an "
                f"assertion of `{tok}` with it")
        if target and asserted(dropped, verb) and verb not in extra_verbs:
            raise CutRefused(
                f"{who}: cutting {path} at `{cut}` takes `{verb}` "
                f"assertions the targeted keep `{tok}` does not hold, and "
                f"the leg's extra asserts no `{verb}` — re-assert it there "
                f"or hold them with the keep")
    return prefix, dropped


# THE DROP: a block out of the middle, where a cut can only take a tail.
# Shared by the phone lanes and the Linux lane (tools/lib/lanes/linux.py),
# since two answers to one question is how lanes drift.


def drop_block(lines, specs, keep):
    """The DROP's decision, over normalized lines and nothing else —
    (kept, dropped), or a ValueError carrying the sentence. Pure so its
    refusals can be watched firing at import (drop_block_selftest)."""
    keeps = keep.split()
    if not keeps:
        raise ValueError(
            f"dropping {list(specs)} with no `keep` verb — say which "
            f"assertions this drop may not take with it, or the leg can "
            f"be trimmed until it asserts nothing")
    at = []
    for spec in specs:
        words = spec.split()
        hits = [i for i, line in enumerate(lines)
                if line.split()[:len(words)] == words]
        if len(hits) != 1:
            raise ValueError(
                f"the scene has {len(hits)} `{spec}` steps and this lane "
                f"drops exactly one — it was reshaped and nobody re-read "
                f"what this lane can express. Fix the leg, do not widen "
                f"the drop.")
        at.append(hits[0])
    at.sort()
    if at != list(range(at[0], at[0] + len(at))):
        raise ValueError(
            f"the dropped steps {[lines[i] for i in at]} are not one "
            f"block — a drop takes a step and the assertions it feeds, "
            f"never a step from the top and an assertion from the bottom")
    gone = set(at)
    kept = [line for i, line in enumerate(lines) if i not in gone]

    def asserted(seq, verb, target=None):
        return {line for line in seq
                if (p := line.split()) and p[0] == verb
                and (target is None or (len(p) > 1 and p[1] == target))}

    for tok in keeps:
        verb, _, target = tok.partition("=")
        whole = asserted(lines, verb, target or None)
        survived = asserted(kept, verb, target or None)
        if not survived:
            raise ValueError(
                f"dropping {[lines[i] for i in at]} leaves no `{tok}` "
                f"step at all — the leg would pass without asserting the "
                f"thing it exists for")
        if survived != whole:
            raise ValueError(
                f"dropping {[lines[i] for i in at]} takes "
                f"{sorted(whole - survived)} — the drop may not take an "
                f"assertion of `{tok}` with it")
    return kept, [lines[i] for i in at]


def drop_blocks(lines, blocks):
    """Every block of a lane's `drop`, in the table's order and each
    refused on its own terms — the blocks of one scene need not be
    contiguous with each other (taskspersist's two sit on opposite sides
    of the `relaunch`). Pure, so the sequencing's own refusal can be
    watched firing at import."""
    taken = []
    for specs, keep, why in blocks:
        lines, gone = drop_block(lines, specs, keep)
        taken.append((why, gone))
    return lines, taken


def drop_block_selftest():
    """The refusals above, watched firing on every launch — the runner
    is the only wall a lane's cut has, and a guard nobody has seen fail
    is worse than none (CLAUDE.md invariant 3)."""
    sample = ['drag label#0 to label#1',
              'expect label#4 "text target got text hello (copy)"',
              'drag_file "$TMP/f.txt" to label#3',
              'expect label#4 "files target got f.txt (copy)"',
              'expect_order column@rows "a|b|c"']
    good = ('drag_file', 'expect label#4 "files target got f.txt (copy)"')
    reds = 0
    for specs, keep, why in (
            (good, "", "no keep verb"),
            (("expect",), "expect_order", "a spec matching four steps"),
            (("scroll_end",), "expect_order", "a spec matching nothing"),
            (("drag_file", 'expect_order column@rows "a|b|c"'),
             "expect_order", "two hits that are not one block"),
            ((good[0], good[1], 'expect_order column@rows "a|b|c"'),
             "expect_order", "a drop taking a keep's own assertion")):
        try:
            drop_block(list(sample), specs, keep)
        except ValueError:
            reds += 1
            continue
        raise AssertionError(f"scene-cut: SELF-TEST FAIL — drop_block accepted {why}")
    kept, gone = drop_block(list(sample), good, "expect_order")
    if len(kept) != 3 or len(gone) != 2:
        raise AssertionError("scene-cut: SELF-TEST FAIL — drop_block refused the real "
                             f"shape ({len(kept)} kept, {len(gone)} dropped)")
    # THE SEQUENCE: a second block is read against what the first LEFT, so
    # one that names a step already taken must be refused rather than
    # quietly dropping nothing.
    two = [(good, "expect_order", "the foreign source"),
           (("drag label#0",), "expect_order", "the local drag")]
    kept, taken = drop_blocks(list(sample), two)
    if len(kept) != 2 or len(taken) != 2:
        raise AssertionError(f"scene-cut: SELF-TEST FAIL — drop_blocks refused two real "
                             f"blocks ({len(kept)} kept, {len(taken)} block(s) taken)")
    try:
        drop_blocks(list(sample), [two[0], two[0]])
    except ValueError:
        reds += 1
    else:
        raise AssertionError("scene-cut: SELF-TEST FAIL — drop_blocks accepted a second "
                             "block naming the step the first had already taken")
    return reds

"""The phone-expressible prefix of a shared scene: everything above the
first `cut` verb. One copy for both phone runners AND tools/check-steps.py,
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
    verbs = [(line.split() or [""])[0] for line in lines]
    if cut not in verbs:
        raise CutRefused(
            f"{who}: {path} has no `{cut}` step, so this lane's cut is "
            f"stale — the scene was reshaped and nobody re-read what the "
            f"phone can express. Fix the leg, do not widen the cut.")
    at = verbs.index(cut)
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

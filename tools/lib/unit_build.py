"""What the windows lane's unit-test build did, for its log (docs/traps.md,
the windows lane over its ceiling on a cold unit-test build)."""

import json


def said(json_text, seconds):
    """One sentence from cargo's --message-format=json stream and the build's
    wall time: whether the kaya library was compiled or fresh."""
    fresh = None
    for line in json_text.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if (m.get("reason") == "compiler-artifact"
                and "crates/kaya#" in m.get("package_id", "")
                and "rlib" in m.get("target", {}).get("kind", [])):
            fresh = m.get("fresh")
    if fresh is None:
        state = "kaya's library reported no artifact"
    elif fresh:
        state = "kaya was fresh"
    else:
        state = ("kaya COMPILED; cargo's reason is the `fingerprint` lines above "
                 "(stale: the changed path, dirty: the unit)")
    return f"deploy-win: the unit test build took {seconds:.0f}s; {state}"

"""What the windows lane's unit-test build did, for its log (docs/traps.md,
the windows lane over its ceiling on a cold unit-test build)."""

import json


def said(json_text, ran, waited):
    """One sentence from cargo's --message-format=json stream, how long the
    build ran and how long the phase waited on it: whether kaya's test binary
    was compiled or fresh."""
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
        state = "kaya's test binary reported no artifact"
    elif fresh:
        state = "kaya's test binary was fresh"
    else:
        state = ("kaya's test binary COMPILED; cargo's reason is the `fingerprint` lines "
                 "above (stale: the changed path, dirty: the unit)")
    return (f"deploy-win: the unit test build ran {ran:.0f}s and the phase waited "
            f"{waited:.0f}s on it; {state}")

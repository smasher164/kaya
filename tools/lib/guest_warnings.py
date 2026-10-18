"""A Rust guest builds without a rustc warning (docs/traps.md, "The unused
ActionRef no build refused"). The guests are examples of the kaya crate, and Cargo's `[lints]`
table and RUSTFLAGS reach the library too, so the wall reads the build's own
transcript: tools/unit-suite.py (rung 1, every gates.py run and matrix), and
the mac builds in tools/validate-mac.py and tools/run-leg.py."""

import re
import subprocess
import sys

HEADER = re.compile(r"^warning: (?!`kaya` \()(.+)$")
SITE = re.compile(r"^\s*--> (?:\S*/)?(guests/[^:\s]+:\d+)")
SUMMARY = re.compile(r'^warning: `kaya` \(example "([^"]+)"[^)]*\) generated (\d+) warnings?')


def findings(transcript):
    """One sentence per warning cargo printed for a file under guests/, and
    one per example whose summary counted warnings no site was read for."""
    out = []
    sited = set()
    what = None
    for line in transcript.splitlines():
        header = HEADER.match(line)
        if header:
            what = header.group(1)
            continue
        site = SITE.match(line)
        if site and what is not None:
            out.append(f"rustc warns in a Rust guest at {site.group(1)}: {what}. A guest builds "
                       f"warning-free; fix the guest (a chained handle nobody keeps ends in `.id()`)")
            sited.add(site.group(1).split("/")[-1].split(":")[0].removesuffix(".rs"))
            what = None
            continue
        summary = SUMMARY.match(line)
        if summary and summary.group(1) not in sited:
            out.append(f"rustc warns {summary.group(2)} time(s) in the Rust guest example "
                       f"{summary.group(1)!r} and this reader found no guests/ site for it; "
                       f"the transcript above carries the warning")
    return out


def build(argv, cwd):
    """Run `argv`, echo its transcript, and answer its exit status with the
    guest warnings it printed."""
    run = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, encoding="utf-8", check=False)
    sys.stdout.write(run.stdout)
    sys.stderr.write(run.stderr)
    return run.returncode, findings(run.stdout + run.stderr)

#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The GTK compile check that check-targets.sh cannot do: gtk-sys needs
# the distro's pkg-config world, so the Linux backend builds nowhere but
# the container. A `cargo check` in the cached image, seconds warm.
#
# It never skips — a gate that quietly passes when docker is down reads
# as "GTK is fine".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if ! docker info >/dev/null 2>&1; then
    echo "check-gtk: docker is not running — cannot compile the GTK backend." >&2
    echo "check-gtk: start Docker and retry (tools/probe-env.sh reports environments)." >&2
    exit 1
fi

# `docker image ls -q` and not `docker image inspect`: with Docker
# Desktop's containerd image store, inspect reports "No such image" for
# an image that `docker run` starts perfectly well, which would turn
# this gate into a permanent false failure.
if [ -z "$(docker image ls -q kaya-linux 2>/dev/null)" ]; then
    echo "check-gtk: the kaya-linux image is missing — run tools/validate-linux.sh once to build it." >&2
    exit 1
fi

# THE LAYOUT CENSUS. gtk::flex::tests exercise the PURE arithmetic
# (main_axis_measure, grow_shares, required_grow_pool,
# table_horizontal_issue) and would stay green while the harness stopped
# CALLING it, called it with the wrong extremes, or stopped measuring
# what it passes — so the production callsites are held here by name.
#
# EVERY entry is watched, in tools/check-steps.sh's target_watch shape:
# a doctored COPY on disk, the substitution count printed, the REAL
# census re-run against that copy, and the exact finding demanded. The
# perturbation is the change that would otherwise be silent, never the
# deletion of the counted string — deleting the string the census counts
# and asserting the count moved proves only that str.count works, which
# is what this replaced (the review of 01dd633).
if ! python3 - <<'PY'
from pathlib import Path
import shutil
import sys
import tempfile

GTK = "crates/kaya/src/gtk.rs"

# (label, needle, the perturbation that would otherwise be silent)
ENTRIES = (
    ("grower-requirement measure test",
     "fn gtk_flex_measure_holds_grower_requirements()",
     "fn gtk_flex_measure_holds_grower_requirements_disabled()"),
    ("never-negative allocator test",
     "fn gtk_flex_allocator_never_negative()",
     "fn gtk_flex_allocator_never_negative_disabled()"),
    ("table viewport overflow test",
     "fn gtk_table_viewport_rejects_overflow()",
     "fn gtk_table_viewport_rejects_overflow_disabled()"),
    ("allocator rounding dust",
     "let rounding_error = (growers.len().saturating_sub(1) as f64) / 2.0;",
     "let rounding_error = 0.0;"),
    ("main-axis measure call",
     "(minimum, natural) = main_axis_measure(&main_children, self.spacing.get());",
     "(minimum, natural) = main_children.iter().fold((0, 0), "
     "|(mi, na), (_, cmin, cnat)| (mi + cmin, na + cnat));"),
    ("cross-axis natural read",
     "c.measure(self.orientation.get(), cross_total).1",
     "c.measure(self.orientation.get(), cross_total).0"),
    ("leading-edge collection",
     "let min_start = edges[0];",
     "let min_start = 0.0;"),
    ("nearest drawn edge",
     "min_drawn = min_drawn.min(end);",
     "min_drawn = min_drawn.max(end);"),
    ("furthest drawn edge",
     "max_drawn = max_drawn.max(end);",
     "max_drawn = max_drawn.min(end);"),
    ("leading-edge underfill refusal",
     "min_start > 2.0",
     "false"),
    ("leading-edge overflow refusal",
     "min_start < -2.0",
     "false"),
    ("assigned-track read",
     "let assigned = table_horizontal_track(&column);",
     "let assigned = viewport;"),
    ("classifier wired into the harness arm",
     "match table_horizontal_issue(min_start, min_drawn, max_drawn, viewport, assigned) {",
     "match table_horizontal_issue(0.0, min_drawn, max_drawn, viewport, viewport) {"),
)


def census(path):
    """The REAL predicate: one sentence per entry that is not present
    exactly once, naming the entry rather than a column of counts."""
    text = Path(path).read_text(encoding="utf-8")
    return [
        f"check-gtk: {path}: {label} appears {text.count(needle)} time(s), "
        f"wanted exactly 1 (`{needle}`)"
        for label, needle, _ in ENTRIES
        if text.count(needle) != 1
    ]


offenders = census(GTK)
for line in offenders:
    print(line, file=sys.stderr)
if offenders:
    raise SystemExit(1)
print(f"check-gtk: GTK layout census — {len(ENTRIES)} entries present exactly once")

work = tempfile.mkdtemp()
shadow = f"{work}/gtk.rs"
source = Path(GTK).read_text(encoding="utf-8")
try:
    for label, needle, replacement in ENTRIES:
        applied = source.count(needle)
        print(f"check-gtk: census self-test — {label} applied {applied} substitution(s)")
        if applied != 1:
            raise SystemExit(
                f"check-gtk: SELF-TEST BROKEN — {label} matched {applied} sites in "
                f"{GTK}, wanted 1. The red below would be a green about an "
                "unperturbed copy."
            )
        Path(shadow).write_text(source.replace(needle, replacement, 1), encoding="utf-8")
        got = census(shadow)
        want = [
            f"check-gtk: {shadow}: {label} appears 0 time(s), "
            f"wanted exactly 1 (`{needle}`)"
        ]
        if got != want:
            print(f"check-gtk: SELF-TEST FAILED — {label} was not refused as demanded.",
                  file=sys.stderr)
            print("wanted:", file=sys.stderr)
            print("\n".join(want) or "  (nothing)", file=sys.stderr)
            print("got:", file=sys.stderr)
            print("\n".join(got) or "  (nothing — the census accepted it)", file=sys.stderr)
            raise SystemExit(1)
finally:
    shutil.rmtree(work, ignore_errors=True)
PY
then
    echo "check-gtk: FAIL — the GTK layout census is not where this gate holds it." >&2
    exit 1
fi

# Same target dir the suite uses; never the mac one, which holds
# host-arch artifacts.
if docker run --rm -v "$ROOT:/work" kaya-linux bash -c '
    cd /work || exit 1
    export CARGO_TARGET_DIR=/work/target-linux
    run_exact_test() {
        local test_name output rc passed
        test_name="$1"
        output="$(cargo test --locked --lib --quiet --features harness \
            "$test_name" -- --exact 2>&1)"
        rc=$?
        printf "%s\n" "$output"
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi
        passed="$(KAYA_CARGO_TEST_OUTPUT="$output" python3 - <<PY
import os
import re

results = re.findall(
    r"test result: ok\. ([0-9]+) passed;", os.environ["KAYA_CARGO_TEST_OUTPUT"]
)
print(sum(map(int, results)) if results else "ambiguous")
PY
)"
        echo "check-gtk: $test_name passed count: $passed"
        if [ "$passed" != "1" ]; then
            echo "check-gtk: $test_name ran $passed tests, expected exactly 1" >&2
            return 1
        fi
    }
    # BOTH feature configurations, the check-targets rule: without
    # --features harness the Stage impl is configured out entirely.
    # (No apostrophes in here: the block is inside a single-quoted
    # bash -c string and one would close it.)
    cargo check --locked --lib --quiet 2>&1 \
        && cargo check --locked --lib --quiet --features harness 2>&1 \
        && cargo test --locked --lib --quiet --no-run 2>&1 \
        && run_exact_test gtk::flex::tests::gtk_flex_measure_holds_grower_requirements \
        && run_exact_test gtk::flex::tests::gtk_flex_allocator_never_negative \
        && run_exact_test gtk::flex::tests::gtk_table_viewport_rejects_overflow \
        && if run_exact_test gtk::flex::tests::check_gtk_zero_test_selftest \
            >/dev/null 2>&1; then
                echo "check-gtk: zero-test self-test was accepted" >&2
                false
            else
                echo "check-gtk: zero-test self-test rejected"
            fi
'; then
    echo "check-gtk: OK"
else
    echo "check-gtk: FAIL" >&2
    exit 1
fi

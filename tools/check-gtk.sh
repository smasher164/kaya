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

gtk_layout_test_counts="$(python3 - <<'PY'
from pathlib import Path
import sys

source = Path("crates/kaya/src/gtk.rs").read_text()
tests = (
    "fn gtk_flex_measure_holds_grower_requirements()",
    "fn gtk_flex_allocator_never_negative()",
    "fn gtk_table_viewport_rejects_overflow()",
    "let rounding_error = (growers.len().saturating_sub(1) as f64) / 2.0;",
    "(minimum, natural) = main_axis_measure(&main_children, self.spacing.get());",
    "c.measure(self.orientation.get(), cross_total).1",
    "let min_start = edges[0];",
    "min_drawn = min_drawn.min(end);",
    "max_drawn = max_drawn.max(end);",
    "min_start > 2.0",
    "min_start < -2.0",
    "let assigned = table_horizontal_track(&column);",
    "match table_horizontal_issue(min_start, min_drawn, max_drawn, viewport, assigned) {",
)

def census(text):
    return [text.count(test) for test in tests]

expected = [1] * len(tests)
for label, needle in (
    ("left-edge collection", "let min_start = edges[0];"),
    ("left-edge underfill refusal", "min_start > 2.0"),
    ("left-edge overflow refusal", "min_start < -2.0"),
):
    applied = source.count(needle)
    print(
        f"check-gtk: {label} self-test applied {applied} substitution(s)",
        file=sys.stderr,
    )
    if applied != 1:
        raise SystemExit(f"check-gtk: {label} self-test changed {applied} sites, wanted 1")
    shadow = source.replace(needle, "", 1)
    if census(shadow) == expected:
        raise SystemExit(f"check-gtk: {label} self-test was accepted")

print(" ".join(map(str, census(source))))
PY
)"
echo "check-gtk: GTK layout measurement test counts: $gtk_layout_test_counts"
if [ "$gtk_layout_test_counts" != "1 1 1 1 1 1 1 1 1 1 1 1 1" ]; then
    echo "check-gtk: expected each GTK layout test and production call exactly once" >&2
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

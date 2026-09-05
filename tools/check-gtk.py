#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir

dev_shell_or_die()

# The GTK compile check check-targets.py cannot do (CLAUDE.md's gate
# list): gtk-sys needs the distro's pkg-config world, so the Linux
# backend builds nowhere but the container. It never skips — a gate that
# quietly passes when docker is down reads as "GTK is fine".

import subprocess

# Line-buffered stdout: the docker run writes to the same fd, and
# block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

GTK = "crates/kaya/src/gtk.rs"

if subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                  stderr=subprocess.DEVNULL, check=False).returncode != 0:
    print("check-gtk: docker is not running — cannot compile the GTK "
          "backend.", file=sys.stderr)
    print("check-gtk: start Docker and retry (tools/probe-env.sh reports "
          "environments).", file=sys.stderr)
    sys.exit(1)

# `docker image ls -q` and not `docker image inspect`: with Docker
# Desktop's containerd image store, inspect reports "No such image" for
# an image that `docker run` starts perfectly well, which would turn
# this gate into a permanent false failure.
if subprocess.run(["docker", "image", "ls", "-q", "kaya-linux"],
                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                  text=True, check=False).stdout.strip() == "":
    print("check-gtk: the kaya-linux image is missing — run "
          "tools/validate-linux.py once to build it.", file=sys.stderr)
    sys.exit(1)

# THE LAYOUT CENSUS: gtk::flex::tests exercise the PURE arithmetic and
# stay green while the harness stops CALLING it or measures the wrong
# thing, so the production callsites are held here by name. Every entry
# is watched in check-steps.py's target_watch shape, and THE
# PERTURBATION IS THE CHANGE THAT WOULD OTHERWISE BE SILENT — never the
# deletion of the counted string, which proves only that str.count works.

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
    ("padded-card truth table",
     "fn gtk_table_padded_card_convicts_nothing()",
     "fn gtk_table_padded_card_convicts_nothing_disabled()"),
    ("slider derivation test",
     "fn gtk_slider_snaps_clamps_and_derives()",
     "fn gtk_slider_snaps_clamps_and_derives_disabled()"),
    # THE VIEWPORT'S FLOOR (docs/deferred.md, closed 2026-08-25): a
    # scrollbar's own 58px minimum reaches the scroller through the
    # POLICY, so a policy pinned open silently brings the empty card back.
    ("the hug's policy write",
     "set_table_scrolling(&body, grown || band.extent > "
     "f64::from(TABLE_MAX_CONTENT));",
     "set_table_scrolling(&body, true);"),
    ("the grow weight the hug consults",
     "grow_weight(column.upcast_ref::<gtk4::Widget>()) > 0.0",
     "true"),
    ("allocator rounding dust",
     "let rounding_error = (growers.len().saturating_sub(1) as f64) / 2.0;",
     "let rounding_error = 0.0;"),
    ("main-axis measure call",
     "(minimum, natural) = main_axis_measure(&main_children, "
     "self.spacing.get());",
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
     "table_horizontal_issue(min_start, min_drawn, max_drawn, viewport, "
     "assigned, reach);",
     "table_horizontal_issue(0.0, min_drawn, max_drawn, viewport, "
     "viewport, reach);"),
    # THE OVERFLOW RULING (2026-08-29): cells past the viewport are what
    # a scrolling table looks like, so the classifier convicts on the
    # SCROLL RANGE — a range read as unbounded makes the trailing-edge
    # clause dead with every scene still green.
    ("the scroll range the overflow clause consults",
     "let reach = table_body_view(&column).map_or(0.0, |view| {",
     "let reach = f64::MAX; let _ = table_body_view(&column).map(|view| {"),
    # THE ROW WINDOW'S THREE LINKS, NONE OF WHICH ANY SCENE CAN SEE:
    # `windowed.steps` passes with each of them cut, because expect_window
    # reads the FIRST VISIBLE row and the band's width deliberately left
    # the verb (docs/virtualization-plan.md §5; docs/traps.md: The GTK row
    # window's three links are invisible to every scene). check-table-tier
    # answers the same wall on the mac tier. Each perturbation below is a
    # plausible SILENT bug rather than a deletion.
    ("window range reported to the core",
     "scene.window_moved(id, first, count)",
     "scene.window_moved(id, 0, usize::MAX)"),
    ("measured row extents reported to the core",
     "scene.rows_measured(id, band.first, &heights);",
     "scene.rows_measured(id, 0, &heights);"),
    ("top spacer sized by the core's arithmetic",
     "let above = (band.offset - spacing).max(0.0);",
     "let above = 0.0;"),
    ("bottom spacer sized by the core's arithmetic",
     "let below = (band.extent - band.offset - realized).max(0.0);",
     "let below = 0.0;"),
    # THE SLIDER'S FIVE LINKS (docs/slider-plan.md S1, S2, S5, S7), THREE
    # OF WHICH tools/scenes/sliders.steps CANNOT SEE — measured, each
    # perturbation below applied to a copy of gtk.rs with the REAL leg run
    # against it (2026-09-04): the pointer's own state stays GREEN, because
    # the scene drives every move through `set_value`, which is a finished
    # gesture with no pointer down, so a drag committing on every pixel is
    # exercised by no leg on any lane; the increments stay GREEN, because
    # they are the keyboard's; the marks stay GREEN, because they are
    # pixels. The first two are the scene's own and were watched going RED,
    # and they stay here as the callsite pins the pure test cannot be.
    ("the slider's snap in the commit path",
     "let value = snapped_slider(slider, raw);",
     "let value = raw;"),
    ("the committed emit at the end of a gesture",
     "sink.send_value_committed_tag(tag, value);",
     "sink.send_value_tag(tag, value);"),
    # A drag's every move would commit — the model and the undo stack
    # written on every pixel, which is what S2 exists to prevent.
    ("the pointer's own state deciding a gesture is over",
     "let settled = !committed.state.get().dragging;",
     "let settled = true;"),
    ("the keyboard's increments derived from the step",
     "        (step, step * 10.0)",
     "        (0.01, 0.1)"),
    # A tick lattice left where the DEFAULT 0..1 range put it: the props
    # arrive in no guaranteed order, so each of the four re-derives.
    ("the ticks re-derived when the range moves",
     "slider.scale.adjustment().set_upper(v);\n                    "
     "slider_marks(slider);",
     "slider.scale.adjustment().set_upper(v);"),
)


def census(path, text):
    """The REAL predicate: one sentence per entry that is not present
    exactly once, naming the entry rather than a column of counts."""
    return [
        f"check-gtk: {path}: {label} appears {text.count(needle)} time(s), "
        f"wanted exactly 1 (`{needle}`)"
        for label, needle, _ in ENTRIES
        if text.count(needle) != 1
    ]


source = (ROOT / GTK).read_text(encoding="utf-8")
offenders = census(GTK, source)
for line in offenders:
    print(line, file=sys.stderr)
if offenders:
    print("check-gtk: FAIL — the GTK layout census is not where this gate "
          "holds it.", file=sys.stderr)
    sys.exit(1)
print(f"check-gtk: GTK layout census — {len(ENTRIES)} entries present "
      f"exactly once")

with scratch_dir("check-gtk-") as work:
    shadow = str(work / "gtk.rs")
    for label, needle, replacement in ENTRIES:
        applied = source.count(needle)
        print(f"check-gtk: census self-test — {label} applied {applied} "
              f"substitution(s)")
        if applied != 1:
            print(f"check-gtk: SELF-TEST BROKEN — {label} matched {applied} "
                  f"sites in {GTK}, wanted 1. The red below would be a "
                  f"green about an unperturbed copy.", file=sys.stderr)
            sys.exit(1)
        doctored = source.replace(needle, replacement, 1)
        got = census(shadow, doctored)
        want = [
            f"check-gtk: {shadow}: {label} appears 0 time(s), "
            f"wanted exactly 1 (`{needle}`)"
        ]
        if got != want:
            print(f"check-gtk: SELF-TEST FAILED — {label} was not refused "
                  f"as demanded.", file=sys.stderr)
            print("wanted:", file=sys.stderr)
            print("\n".join(want) or "  (nothing)", file=sys.stderr)
            print("got:", file=sys.stderr)
            print("\n".join(got) or "  (nothing — the census accepted it)",
                  file=sys.stderr)
            sys.exit(1)

# Same target dir the suite uses; never the mac one, which holds
# host-arch artifacts. The in-container payload is a LAUNCHER and stays
# shell (CLAUDE.md's python-first boundary).
CONTAINER = """
    cd /work || exit 1
    export CARGO_TARGET_DIR=/work/target-linux
    run_exact_test() {
        local test_name output rc passed
        test_name="$1"
        output="$(cargo test --locked --lib --quiet --features harness \\
            "$test_name" -- --exact 2>&1)"
        rc=$?
        printf "%s\\n" "$output"
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi
        passed="$(KAYA_CARGO_TEST_OUTPUT="$output" python3 - <<PY
import os
import re

results = re.findall(
    r"test result: ok\\. ([0-9]+) passed;", os.environ["KAYA_CARGO_TEST_OUTPUT"]
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
    cargo check --locked --lib --quiet 2>&1 \\
        && cargo check --locked --lib --quiet --features harness 2>&1 \\
        && cargo test --locked --lib --quiet --no-run 2>&1 \\
        && run_exact_test gtk::flex::tests::gtk_flex_measure_holds_grower_requirements \\
        && run_exact_test gtk::flex::tests::gtk_flex_allocator_never_negative \\
        && run_exact_test gtk::flex::tests::gtk_table_viewport_rejects_overflow \\
        && run_exact_test gtk::flex::tests::gtk_table_padded_card_convicts_nothing \\
        && run_exact_test gtk::flex::tests::gtk_slider_snaps_clamps_and_derives \\
        && if run_exact_test gtk::flex::tests::check_gtk_zero_test_selftest \\
            >/dev/null 2>&1; then
                echo "check-gtk: zero-test self-test was accepted" >&2
                false
            else
                echo "check-gtk: zero-test self-test rejected"
            fi
"""

run = subprocess.run(
    ["docker", "run", "--rm", "-v", f"{ROOT}:/work", "kaya-linux",
     "bash", "-c", CONTAINER], check=False)
if run.returncode == 0:
    print("check-gtk: OK")
else:
    print("check-gtk: FAIL", file=sys.stderr)
    sys.exit(1)

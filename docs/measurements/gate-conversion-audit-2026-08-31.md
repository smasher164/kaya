# Bash-to-python gate conversion — merged audit

37 gates audited across 12 groups (the per-group reports lived in the
session scratchpad and were not retained; this merged summary is the record).
Every group recovered the pre-conversion shell body from the adding commit's
parent and compared it clause by clause against the current `tools/<g>.py`.

**4 REAL findings. 71 minor findings.**

Accepted, non-finding deviations everywhere (per the audit charge): `doctor()`'s
`self-test <label>, N substitution(s)` lines, `N watched negative(s) ran`,
`counted()` floor lines, `REFUSAL — ` prefix wording, scratch-dir naming.

---

## REAL findings, ranked by severity

| # | gate | `.py` line | defect | consequence |
|---|---|---|---|---|
| 1 | check-wheel | 59-60 (smoke `subprocess.run`, no `cwd=`) | The import smoke lost the shell's `cd "$ROOT"` (old `.sh:21`), so it runs with the INVOKER's cwd and `python -c` puts `''` at `sys.path[0]` | **False green, reachable today.** Run standalone from `bindings/python` (or `android/pyhost/src/main/assets/python/app`) and `import kaya` / `kaya.wire` / `kaya.runtime` resolve from the WORKING TREE ahead of the venv, so the gate prints `check-wheel: OK` for a wheel that ships none of them — the exact hole the gate's own comment exists to close, on the one leg that sees what the wheel actually ships. `gates.py` is unaffected (it passes `cwd=root`), so only the standalone runs CLAUDE.md blesses are exposed. Fix: `cwd=ROOT`, or better `cwd=tmp`. |
| 2 | check-shell | 14-21 (header claim); populations at 55, 90, 110, 204, 263, 321 | Four of the five repo rules keep a `*.sh`-only population while the bodies they policed moved to `.py`, and the file's header asserts the opposite ("ITS SCOPE DID NOT SHRINK, ITS POPULATION DID … the rules that DO apply are check-python's"). `tools/check-python.py:18-52` has no `--locked`, no `-encoding UTF-8`, no sed/awk ban, no ffmpeg `-nostdin` — only the `$?` rule genuinely has no python analogue | **Systemic guard hole created by the conversion itself.** Measured: 7 javac sites left `java-typecheck`, 1 left `check-abort`, 4 cargo sites left `check-gtk` — 12 sites that used to be scanned and now are not. All 12 still comply, so nothing is in breach; but a thirteenth written tomorrow in any of the 68 `tools/*.py` files produces no finding anywhere, where before it produced a `check-shell` red. CLAUDE.md still states "Every cargo invocation carries `--locked` (check-shell enforces it)". Minimum honest fix: amend the header to name the four rules that lost their population; real fix: four rules in check-python, or four populations widened to `*.py`. |
| 3 | check-case | 64-66 (`git ls-files` result; `returncode` read nowhere) | The shell ran `git ls-files -z \| … \| lint -` under `set -uo pipefail`, so git's non-zero status became the pipeline's and took the `!` branch; the port keeps whatever partial stdout git produced and never reads `returncode` | **False green.** The gate's entire population comes from that one subprocess, so a git that ran and failed (broken index, unreadable `.git`) yields no offenders and `check-case: OK`. Nothing else notices: there is no `counted(..., floor=)` on the 1,233 tracked paths either. A missing `git` still raises `FileNotFoundError`, so only the ran-and-failed case is silent. The class this gate exists for dies on the lane furthest from the change, after a full matrix. |
| 4 | check-ambient-tx | 49 (`for f in sorted((ROOT / "guests/python").glob("*.py"))`) | Bash left an unmatched glob literal, `open()` raised, the `\|\|` branch fired and the gate exited 1; the python loop simply does not execute | **Latent vacuous green.** If the python guests are moved or renamed the gate goes from red to green — "a census that read nothing agrees with everything". Population is 45 files today. Weighted lowest because the old red was incidental (a traceback misreported as "opens a transaction INSIDE a handler"), not designed, and the port legitimately escapes check-python rule 5, which pairs floors only with `Gate.walk()`, not `.glob()`. |

---

## Minor findings per gate (71 total)

| gate | minor | gate | minor |
|---|---|---|---|
| check-app-identity | 6 | check-symbols | 2 |
| flightrec-selftest | 5 | check-targets | 2 |
| check-c-bounds | 5 | java-typecheck | 2 |
| check-abort | 4 | check-verbs | 2 |
| check-c-ids | 4 | check-shell | 2 |
| check-go-env | 4 | check-case | 1 |
| check-build-id | 3 | check-detekt | 1 |
| check-tx-liveness | 3 | check-stubs | 1 |
| check-empty-child | 3 | check-pane-ladder | 1 |
| check-design-generation | 3 | check-keyed | 1 |
| check-harness-ceiling | 3 | check-gtk | 1 |
| check-pins | 3 | check-staging | 1 |
| check-assets | 3 | check-wheel | 1 |
| check-table-tier | 3 | check-diagnostics | 1 |

Zero minor findings, zero REAL: **check-compose, check-mirror, check-accent,
check-symbol-parity, check-roles, check-native-undo, check-file-modes,
check-canvas-blit** (8 gates fully clean). check-ambient-tx has 0 minor but
carries REAL #4.

### Shared-helper patterns, merged across groups

Nine classes were flagged independently by two or more groups. Each is counted
once per gate above but is ONE decision, in `tools/lib/kaya_gate.py` or in the
port recipe, not N unrelated slips.

1. **`doctor()` dropped the shell's `count=1` / `applied() >= 1` became exact
   `want=N`** — flagged by groups 3, 5, 6, 7, 8, 9, 10, 11 (check-accent,
   check-tx-liveness, check-empty-child, check-roles, check-native-undo,
   check-harness-ceiling, check-c-ids, check-file-modes, check-canvas-blit,
   check-go-env, check-c-bounds, check-app-identity, check-assets). Every group
   measured its patterns against the live tree and every one matches its
   declared `want` today (check-canvas-blit's `want=3`, check-app-identity's
   `want=3`, check-verbs' `want=3` included). The failure direction is a false
   RED (`SELF-TEST BROKEN`), never a silenced red. **Net improvement**, and it
   matches the repo's own c98e4c6 ruling.
2. **Uncaught `Refusal` prints a traceback after the sentence** — groups 8, 10,
   11 (check-harness-ceiling M1, check-c-ids M2, check-c-bounds M2,
   check-app-identity M4, check-diagnostics). `g.refuse()` raises and nothing
   catches it at module scope. Exit is 1 either way; the noise follows a correct
   sentence, on paths no green run takes. One fix in the prelude closes all five.
3. **A missing file or tool is now a traceback instead of the gate's own named
   finding** — groups 0, 2, 3, 4, 5, 6, 8, 9, 10 (check-compose recorded,
   check-mirror recorded, check-abort M2/M3, check-build-id M1, check-targets M2,
   check-tx-liveness M3, check-design-generation, flightrec M5, java-typecheck
   M1). `read_text` / `subprocess.run` raise where `grep` exited 2 and `xcrun`
   exited 127. Always non-zero, never a silenced red; what is lost is the
   sentence naming the list to extend, and in check-build-id's case the five
   later clauses that used to keep running.
4. **`subprocess.run(text=True)` with no explicit `encoding=`** — groups 1, 3, 6
   (check-case M1, check-build-id M3, check-design-generation). Decodes with the
   locale's encoding on failure paths that carry em-dashes; latent, and only
   under `PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 LC_ALL=C`. The one rule-4 gap the
   conversion left.
5. **`g.perturb` names the scratch file after the SOURCE basename**, so N
   perturbations of one file share a path — groups 8 and 9
   (check-harness-ceiling #3, check-canvas-blit #1). Safe ONLY because
   `g.negative` evaluates its callable immediately and `check()` re-reads
   pristine text. **Latent hazard worth a comment at both sites**: collect the
   lambdas and run them later — the deferred shape — and every negative reads
   the last doctored copy and most go green for the wrong reason.
6. **A signal-killed child reports a negative returncode** where the shell
   printed 128+N — groups 2, 6, 10 (check-pane-ladder, check-empty-child,
   check-c-bounds M5). Cosmetic in all three. Worth recording that check-c-bounds
   is the one gate where a naive port WOULD have been REAL (a `rc in (138,139)`
   test against `-11` makes a permanent false red), and it was handled correctly
   with `fault_signal()` accepting both encodings.
7. **`shutil.copytree(symlinks=False)` dereferences where `cp -R` preserved** —
   groups 5, 8 (check-staging, check-c-ids M1). No symlinks exist under any
   shadowed tree today; both verified rather than assumed.
8. **`grep -c` counted LINES, `str.count` counts OCCURRENCES** — groups 5, 8, 10
   (check-tx-liveness M1, flightrec #8 handled per-line, check-c-bounds #7). All
   measured equal on the real files; direction is stricter for exact-count
   clauses (check-tx-liveness CLOSES a hole) and laxer only in contrived shapes.
9. **The dev-shell refusal now names `tools/<g>.py`** where `$0` named the
   `.sh` the reader typed — groups 1, 2, 4, 9, and applies to all 37. Sentence
   bodies are byte-identical and watched by `kaya_gate --selftest` F2. Cosmetic.

**One cross-group class that reaches REAL:** the missing census floor. Group 1
rated check-ambient-tx's REAL (#4 above), group 1 noted check-case has no floor
on its 1,233 paths (compounding REAL #3), and group 2 recorded the same residual
in check-stubs' 48-scene walk — present in BOTH bodies there, so not a port
regression, but the same "a census that reads nothing agrees with everything"
shape in three gates. `check-python.py` rule 5 pairs floors only with
`Gate.walk()`, so `.glob()`-driven censuses are outside it.

**Improvements the port made, recorded so nobody reverts them:** the in-process
scans removed the shell's `|| true` swallows and unread heredoc statuses
(check-pins minor 1, check-shell minor 2, check-file-modes #5 — a traceback in
340 lines of scanner used to leave `findings` empty and print OK); five
self-tests now close over the REAL detector objects instead of hand-typed copies
(check-shell, check-pins, check-stubs, check-mirror, check-symbol-parity's added
N5); check-staging's `shadow()` no longer reads from the caller's cwd; flightrec
N5's `applied` no longer feeds a hard-coded `print(1)`; check-app-identity
dropped a duplicated `PRUNE` table; check-c-bounds' `fault_signal()` fixed the
signal-encoding trap outright.

---

## Verdict on the conversion set

The conversion is faithful. Across 37 gates the auditors compared message sets
mechanically rather than by eye — AST-diffing bodies, `ast.literal_eval`ing
tables, hashing heredoc payloads, and in four cases running the OLD shell body
and the NEW python side by side over doctored inputs (check-symbol-parity 15/15
variants byte-identical including all three refusal branches, check-keyed 11/11
with `subprocess` mocked, check-stubs 240 census cells, check-canvas-blit 18
perturbations compared by sha256) — and the recurring result is zero drift in
the text a green run never prints, which is the half a lane cannot see. Only
four REAL findings surfaced, and only two of them can manufacture a false green:
check-wheel's lost `cd` (reachable today from a plausible cwd, and squarely an
invariant-4 breach — the gate can be satisfied without exercising the wheel) and
check-case's swallowed `git ls-files` status. The third, check-shell's shrunken
population, is the conversion program auditing itself and finding that it
disarmed four of its own rules while its header and CLAUDE.md both still claim
otherwise — no false green, but the largest standing coverage loss and the one
whose fix belongs in the same commit as the claim. The fourth is latent. The 71
minor findings are dominated by nine shared-helper decisions, not by 71
independent slips: the `want=N` tightening (an improvement, verified honest
against the live tree in every gate that uses it), tracebacks replacing named
sentences on paths no green run takes, and cosmetic stream or exit-code
spellings. Two things deserve a comment rather than a fix: the scratch-filename
reuse in `g.perturb`, which is correct only while negatives are evaluated
eagerly, and `check-python.py` rule 5's blindness to `.glob()`-driven censuses,
which is the shape behind two of the four REAL findings.

# Row windowing: virtualization for For

RATIFIED 2026-08-24 (option B, the maintainer's shape after three
rounds of his questions sharpened it): ALWAYS WINDOWED, NO API SURFACE,
variable height in contract from day one. Argued from measurements —
the five-platform choke baseline (docs/measurements/
choke-*-2026-08-24.txt) and the fix slice (a5f6189) that left per-row
cost as every platform's only residue: one SwiftUI attribute-graph node
per row on the mac native tier, full widget realization per row on the
four synthesized tiers (Android OOMs at ~4-5k rows on Compose state,
GTK saturates its main thread, X11 refuses unbounded natural height
past 32,767px).

## §1 — The one rule

Every For's rows exist as DATA always and as WIDGETS only while near
the viewport. There is no opt-in, no second widget and no property:
kaya's For is already the template/factory form the industry's Lazy
widgets exist to impose, so one construct serves both scales. At small
N the band covers every row and windowing is observably invisible —
which is how every platform's own list already behaves.

- The collection is whole: inserts, updates, moves and reads work on
  every row, realized or not. "Order is data, keys are identity" does
  not bend. (The pump-cap deletion made whole-collection data cheap:
  25,000 rows in one transaction, measured.)
- The stamped copy exists only inside the REALIZED BAND: the viewport
  plus one viewport of overscan each side. Rows entering stamp; rows
  leaving tear down. Stamping-on-entry reads current data, so an
  update to an unrealized row costs a model write and nothing else.
- The guest writes ZERO windowing code and makes ZERO promises. The
  backend (which owns scroll geometry) drives; the core (which owns
  stamping) serves.

## §2 — Heights: presume, verify, correct

The uniform case must cost nothing and the variable case must work.
One machine, two paths, chosen per For by measurement:

1. **Presume**: the first stamped row's measured extent along the
   scroll axis — its PITCH, the top-to-top repeat distance including
   spacing — is presumed for every row. Never a typed constant
   (Flutter's own prototypeItem argument, stronger here: one number
   cannot be right on five platforms' text metrics at once).
2. **Verify**: every realized row is measured. While every measurement
   equals the presumption, the For is on the EXACT path: extent is
   N x pitch, positions are multiplication, and every windowing
   observable is a pure function of N and pitch — byte-deterministic
   on every lane.
3. **Correct**: the first mismatched measurement moves that For to the
   CORRECTED path, silently and permanently (for the instance's life):
   measured heights are cached, positions come from a prefix-sum over
   measured-or-presumed heights, and the total extent re-derives as
   realizations land. Uniform data can never reach this path, which is
   what makes §2.2's determinism claim honest rather than hopeful.
4. **Anchor**: scroll position is anchored to ROW IDENTITY plus offset
   into that row, never to pixel extent — corrections above the
   viewport adjust the scrollbar, not the content under the reader's
   eyes. This is the policy the industry's scars orbit (GTK's
   scrollbar-drag broken with uneven rows by their own blog, Qt's
   30%-off jumps, Flutter's standing variable-extent issue); it is
   designed and watched here, not inherited.

## §3 — The wire and the drive loop

1. There is NO WIRE declaration: the For's existing record is enough and
   no guest spells anything. The BACKEND declares — core-internally, at
   its own init, no wire record and no binding surface — that it windows
   rows (docs/deferred.md's declares-windowing entry, ruled 2026-08-25).
   That declaration is what SEEDS a windowed-capable For's band at a
   screenful instead of the whole collection: a report needs a layout,
   and a single-transaction fill does not wait for one.
2. **The report**: a backend laying out a For whose content overflows
   its band calls `kaya_window_moved(for_target, first_index,
   visible_count)` on the C ABI whenever the visible range changes
   (scroll, resize, first layout). BACKEND plumbing, never app
   surface: no binding exposes it, no guest implements a callback, no
   data is supplied on demand — the collection already holds every row
   from the guest's own inserts. The cellForRowAt-style pattern is
   exactly what this design rejects. Indices, not keys: the band is a
   POSITION over the collection's current order, and rows flow through
   it under sorts exactly as platform tables behave.
3. **The serve**: the core derives the band (visible ± one viewport),
   diffs it against the realized set, and emits ordinary stamp applies
   for entering rows and teardown applies for leaving rows on the
   normal pump stream. THIS IS A SECOND PRODUCER for that stream —
   today every apply descends from a guest transaction — and the
   contract is stated once: window applies are core-internal, never
   re-enter the guest, and serialize with transaction applies on the
   one pump (one consumer, one ordering; tx-liveness is untouched
   because no guest transaction exists here).
4. **Heights ride the report**: the backend reports each realized
   row's measured extent with the range (the verify half lives where
   measurement lives). The core owns the presumption, the cache, the
   prefix sums and the path choice, so all five backends share one
   correctness story and the harness reads one model.

## §4 — Per-tier lowering (one rule, five spellings)

- **macOS native table**: stops being SwiftUI `Table` (one
  attribute-graph node per row by design — measured at 39% of the
  frame, confirmed by the platform literature). Becomes NSTableView
  through NSViewRepresentable with a REAL DATA SOURCE: numberOfRows =
  N, cells recycled by the platform, each hosting the stamped row's
  widgets while realized. Per-row heights are driven from the CORE's
  cache through the delegate, so AppKit asks us and there is ONE
  estimator, not two. NSTableView's own visible range is the report.
- **GTK, WinUI, Compose, iOS-compact (synthesized), and every
  non-table For on every tier**: the classic window — top spacer
  (position of `first` from the core's arithmetic), the realized
  band's real widgets, bottom spacer (extent minus band) — inside the
  scroll container the tier owns. One geometry rule, five spellings.
  GtkListView/ItemsRepeater recycling stays rejected (the 2026-08-21
  probe: list items own their children; stamped widgets cannot be fed
  to them). Compose spells the same spacer+band rather than
  LazyColumn: one observable mechanism, and the core owns the band.
- The X11 height ceiling dies for windowed content by construction
  (two spacers regardless of N).

## §5 — Observables and the two scenes

- `expect_rows` reads REALIZED WIDGETS (amended 2026-08-25 — the
  implementations walk real children, and a band-wide listing's length
  is a viewport metric), so scenes assert it only where the band
  covers the whole collection; whole-collection facts ride labels and
  totals computed from data.
- New byte-shared verb `expect_window <target> <first_visible> <N>`
  (RULED 2026-08-25, after the first live run showed the two depth
  halves splitting exactly here): the FIRST VISIBLE row and the
  declared total, both data — after scroll_to_row the first visible
  row IS the scrolled-to row, on either arithmetic path. The realized
  band's WIDTH is a viewport metric and left the verb: the band
  arithmetic is held by the core's own watched tests (rowwindow.rs),
  and the compiled table-tier probe holds the view layer's contract —
  the unreported fallback band, and a firstVisible that reads the
  viewport rather than the band (an echoing firstVisible reds the
  probe). A scroll clamped at the collection's end leaves first
  visible metric-dependent, so end-scrolls run unasserted.
- `scroll_to_row <target> <key>`: the companion admission the ledger
  already pairs with this milestone — core maps key to index, backend
  scrolls, band follows. Addresses the ROW (data), so unrealized rows
  work by construction.
- The realization census (partialRow/unrealized vocabulary) learns the
  band as the universal rule: every tier owes exactly the band's rows.
  At small N the band is all rows, so existing scenes keep their
  meaning unchanged.
- **ledger.steps — the uniform scene**: the transactions view's shape
  at 15,000 generated rows (above WinUI's 12,000, the strongest
  measured non-virtualized choke). Exact path throughout: assert first
  rows, expect_window at the top, scroll_to_row to the middle and end,
  expect_window each time, sort and re-assert, tick and re-assert.
  Byte-deterministic everywhere because uniform data never corrects.
- **varied.steps — the variable-height scene** (maintainer,
  2026-08-24: a scene that can test variable height ships WITH the
  machine — invariant 4 forbids correction that nothing exercises).
  Variance is STRUCTURAL, not typographic, so it is deterministic on
  every platform: each row's template holds an inner For of k lines
  where k derives from the row's data (1..5, from the generator's own
  arithmetic). The scene drives the correction path on purpose:
  scroll_to_row deep past unmeasured rows (positions presumed), then
  back (positions corrected), asserting the CORRECTION-STABLE facts —
  band membership by row identity, first-visible row identity after
  each move, counts and N — never pixel extents, which are legitimately
  platform- and history-dependent on this path. A final anchoring
  assertion: with the viewport parked on a row, realizing taller rows
  above it must not move that row out of the viewport (the sentence
  the anchoring policy exists to keep true).

## §6 — Sequencing (each layer proven before the next)

1. Protocol root: `kaya_window_moved` + height reports +
   `scroll_to_row` + teardown applies + the second-producer contract;
   core band/presume/verify/correct/anchor logic with unit tests
   (band diffs, sort-under-band, update-unrealized, exact-to-corrected
   transition, prefix-sum positions, anchor stability) — the exact
   path's tests watched red first, then the corrected path's.
2. Mac depth: the NSTableView data-source tier, expect_window +
   scroll_to_row on the mac stage, ledger.steps AND varied.steps, the
   Python transactions view (with the Python insert fix, which is on
   this path) — AS ITS OWN GUEST, guests/python/ledger.py, until
   breadth: portfolio.steps runs on the linux and windows lanes today,
   where an un-windowed 15k-row stamp still chokes; the view joins the
   portfolio when §6.3 lands (amended 2026-08-25). varied.steps is a
   ONE-COLUMN TABLE, not a plain For — §6.2 windows the mac table
   tier; the plain-For band is §6.3's. GTK and WinUI carry the
   depth_stub calls meanwhile, and the python guests keep ledger and
   varied on the mobile lanes' UNWIRED lists. validate-mac green.
3. Breadth: the four synthesized spacer+band tiers in parallel
   worktrees; no binding surface moves (there is nothing to spell —
   the census's job is confirming NOTHING appeared). Matrix.
4. The before/after: the choke bench recipes re-run — acceptance is
   the old chokes passing with headroom (Android's 4-5k OOM must
   become 15k green; mac's per-row attribute-graph cost must be gone
   from the sample), plus varied.steps green on every lane.

## §7 — What was considered and rejected, so nobody re-litigates

- A `windowed`/`uniform_rows` opt-in (property or word): rejected by
  the maintainer's own reduction — the industry's property opt-in
  (WPF) is a famous silent-failure trap, its separate-widget pattern
  (everyone else) exists only to impose the template form kaya's For
  already has, and a consent word for the mismatch wall is unnecessary
  once mismatch is HANDLED rather than fatal.
- Typed pitch values (itemExtent-style): rejected — one constant
  cannot be right on five platforms' text metrics; the prototype
  measurement is per-platform-correct by construction.
- Crash-on-mismatch v1 with correction deferred to an artifact:
  rejected by the maintainer — correction is windowing's natural
  contract, the ledger is the milestone's artifact, and the flaws are
  on the roadmap either way; they get debugged here, against
  varied.steps, with watched negatives.
- cellForRowAt-style on-demand data callbacks: rejected — windowing
  code in every app in eight languages.
- Compose LazyColumn as that tier's spelling: rejected for one
  observable mechanism; revisit only if a measurement demands it.

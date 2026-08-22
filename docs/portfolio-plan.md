# The portfolio dashboard — the design pass

Status: v1 skeleton STARTED 2026-08-21 (this pass; the maintainer's
"go ahead and start"). The second forcing app, the editor's role one
milestone over (docs/editor-plan.md is the precedent this file
follows).

## §0 — what is already ratified (all maintainer, 2026-08-21)

- **This app exists to force three features**: dynamically created
  tables (a table per data item — the ledger's HIGH PRIORITY entry),
  the canvas widget (price charts), and row virtualization (a large
  transactions view). Each lands against this app, not against a
  synthetic scene.
- **Written in PYTHON** — "worthwhile to invest in one other language
  just for diversity's sake." The editor took Go so a binding's
  awkward corners would show; this slot spends the same currency on
  the ambient-transaction, dynamic-language binding. Consequence: the
  app runs the THREE DESKTOP LANES until the packaging milestone
  bootstraps CPython into the APK and the iOS bundle (official
  upstream support exists: PEP 730/738); the mobile lanes carry it as
  declared-off-with-a-reason until then.
- **Synthetic, deterministic data** — the editor's discipline: every
  number in the scene is computed from fixed inputs, so the byte-frozen
  scene stays honest.

## §1 — the v1 surface (this slice; today's vocabulary only)

One window, a two-column row: LEFT is the portfolio — a total, a "Day
tick" button, and the account list (a For of stamped buttons, one per
account, each carrying its name and total); RIGHT is the selected
account's detail — its name, its positions TABLE (Ticker | Qty |
Price | Value, click-to-sort via the tables vocabulary), and its
total.

Deliberate v1 choices, each a recorded stop short of a forced feature:

- **One table, driven by selection.** A table per account card is the
  fenced dynamic-tables shape; v1 keeps ONE positions collection and
  repopulates it when an account button is clicked. The repopulation
  handler is exactly the code a dynamic-tables landing deletes.
- **No chart.** The portfolio total is a label; the canvas slice will
  replace the space above it with a value-over-time chart. The "Day
  tick" button exists partly to accumulate the series a chart will
  want.
- **A small book.** Three accounts, six tickers. The transactions
  view (and the virtualization it forces) is a later slice; v1 stamps
  every row it has.
- **A plain row, not panes.** The adaptive-panes vocabulary buys its
  keep when compact widths exist; the desktop skeleton is a fixed
  two-column row. Panes join when the mobile lanes do.
- **Sort resets on selection** — the indicator is re-declared with no
  sort when the collection repopulates. Per-account sort memory is an
  app nicety for a later pass, noted here so it is a decision and not
  an accident.
- **Money is integer cents formatted "$D.CC" with NO thousands
  separator** — expect_rows joins cells with commas, and a comma
  inside a cell makes the frozen string ambiguous to the eye (it stays
  byte-comparable, but the scene should read plainly).

## §2 — the tick

"Day tick" applies a FIXED per-ticker price delta (cents: AAPL +250,
NVDA -1000, VTI +75, BND -10, VXUS +60, CASH 0), recomputes every
value and total, and rewrites the visible labels and rows. It is the
app's one source of change beyond selection — deterministic, so the
scene can assert exact post-tick money — and it is the seed of the
chart series the canvas slice will draw.

## §3 — the scene (tools/scenes/portfolio.steps)

Byte-frozen on the three desktop lanes. The assertions walk: initial
totals and the Brokerage table (expect_columns / expect_column_edges /
expect_rows); select Retirement (a stamped button's real click) and
the detail follows; sort by Value both directions (the guest's policy:
same column flips, new column ascending — numeric compare on cents,
never on the money string); re-select Brokerage and the indicator
resets; one tick and every total moves to its precomputed value.
Leaf targets are positional (body order is screen order everywhere);
the TABLE is addressed by AUTHORED KEY — `column@positions`, the
`kind@id` grammar this scene forced into existence (the ledger's
test_id entry, addressing half): container creation order is
per-language, the container lint rightly forbade `column#3`, and the
maintainer chose the real fix over an exemption.

## §4 — sequencing

1. This slice: the app + scene, legs on mac/linux/windows, mobile
   lanes declared off with the packaging reason. (Alone in its lane
   blocks like the editor only where a lane's conventions require it;
   this app opens no OS chrome and injects no keys, so it pools.)
2. The packaging milestone (ledgered): CPython + the binding into the
   APK and the iOS bundle; the mobile legs then wire and the panes
   pass joins.
3. The three feature slices land against it, in the ledger's order:
   dynamic tables (the per-account tables this file works around),
   canvas (the chart), virtualization (the transactions view).

## §5 — findings ledger

The reason the app exists: every place the BINDING made this app
awkward gets a line here, the editor's discipline.

- **The window-block mirror strictness forced a fill/repopulate
  split (2026-08-21, minutes into the app).** Python guards
  collection READS everywhere construction is live — stricter than
  the other bindings' template-only guard — so a repopulate() that
  clears by iterating items() cannot also serve as the initial fill
  at the bottom of the window block. The app carries fill_positions()
  (writes only, build-legal) beside repopulate() (handlers only), and
  the first thing this app learned is that the strictness is
  DOCUMENTED but easy to walk into: the error's fix-suggestion names
  templates, not the window block. A friendlier sentence for the
  build-time arm is a binding nicety worth a look.
- **The scene grammar could not address the app's table (2026-08-21,
  the same afternoon).** Four columns in one layout and the container
  lint rightly refusing `column#3` — the first single-guest scene to
  need container targets. Resolved by pulling the ledgered test_id
  addressing half forward: `kind@id` against the authored a11y_id, in
  all three harness implementations, with `columns(a11y_id=)` growing
  into the Python sugar. The app is already the forcing artifact the
  plan promised, twice in one day.

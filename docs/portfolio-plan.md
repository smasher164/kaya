# The portfolio dashboard — the design pass

Status: the dynamic-tables shape replaced the v1 selection workaround
2026-08-23, and the Rust/Python depth slice is ALL PASS through the
five-lane matrix. The desktop scene is live; mobile stays declared off
until Python packaging. The second forcing app, the editor's role one
milestone over (docs/editor-plan.md is the precedent this file follows).

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

## §1 — the surface

One window, a two-column row: LEFT is the portfolio total and "Day
tick" button; RIGHT is a For of account cards. Every account copy owns
its name, total, and positions TABLE (Ticker | Qty | Price | Value).
The table is a nested collection instance keyed by that account, and
each copy owns its sort indicator and order.

Deliberate v1 choices, each a recorded stop short of a forced feature:

- **One table per account.** This is the dynamic-tables forcing shape:
  the nested collection is declared inside the account template and
  mutated through `positions.at(account)`.
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
- **Sort state is per account** — clicking one header reorders and
  re-declares only that copy; its siblings retain their own indicators
  and order.
- **Money is integer cents formatted "$D.CC" with NO thousands
  separator** — expect_rows joins cells with commas, and a comma
  inside a cell makes the frozen string ambiguous to the eye (it stays
  byte-comparable, but the scene should read plainly).

## §2 — the tick

"Day tick" applies a FIXED per-ticker price delta (cents: AAPL +250,
NVDA -1000, VTI +75, BND -10, VXUS +60, CASH 0), recomputes every
value and total, rewrites all three nested collection instances, and
re-applies each account's independent sort. It is deterministic, so
the scene can assert exact post-tick money, and it is the seed of the
chart series the canvas slice will draw.

## §3 — the scene (tools/scenes/portfolio.steps)

Byte-frozen on the three desktop lanes. The assertions read all three
tables, sort Retirement by Value in both directions, prove Brokerage
and Savings keep an empty indicator, give Brokerage its own Qty sort,
then tick every price and prove both independent sorts survive.
Leaf targets are positional; each table is addressed as
`column@positions[account]`. The authored id identifies the template
node and the bracketed string-key path identifies its stamped copy.

## §4 — sequencing

1. Dynamic tables — GREEN at depth: the app + divergence scene on
   mac/linux/windows; mobile remains declared off with the packaging
   reason. The app opens no OS chrome and injects no keys, so it pools.
2. The packaging milestone (ledgered): CPython + the binding into the
   APK and the iOS bundle; the mobile legs then wire and the panes
   pass joins.
3. The remaining feature slices land in the ruled order:
   virtualization (the transactions view), then canvas (the chart).

## §5 — findings ledger

The reason the app exists: every place the BINDING made this app
awkward gets a line here, the editor's discipline.

- **The window-block mirror strictness forced the original
  fill/repopulate split (2026-08-21).** Dynamic tables deleted that
  workaround: construction only inserts into each `positions.at(key)`;
  handlers read and mutate the already-existing instances.
- **The scene grammar could not address the app's table (2026-08-21,
  the same afternoon).** Four columns in one layout and the container
  lint rightly refusing `column#3` — the first single-guest scene to
  need container targets. Resolved by pulling the ledgered test_id
  addressing half forward: `kind@id` against the authored a11y_id, in
  all three harness implementations, with `columns(a11y_id=)` growing
  into the Python sugar. Dynamic tables extended the same route to
   `kind@id[key.path]`; its untyped segments deliberately match string
   keys only, so numeric keys never collide with numeric-looking strings.
- **Python's ordinary For surface could not declare its geometry from
  rows() (2026-08-23).** The other seven bindings already could. The
  forcing shape needs grow and stretch on the accounts For, grow on the
  account card, and grow on the positions table, so Collection.rows now
  carries grow/align/a11y_id. Its three handoffs and three emitters have
  independent watched perturbations; the app's three nested geometry
  declarations are probed separately.
- **The first refreshed screenshots found what the model assertions did
  not (2026-08-23).** GTK's flex measure summed unequal grower naturals
  before allocating equal tracks, so the first table overlapped its
  account total. macOS stretched the detail but not the new accounts For,
  leaving all four native columns inside a 145pt viewport. The fixes and
  measured guards are recorded beside the dynamic-table ledger entry and
  in docs/traps.md; the scene now pins 800x600, both nested alignments,
  table containment, and horizontal cell edges for all three copies,
  repeated after each sort re-declaration and the live price tick.

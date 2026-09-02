# The portfolio dashboard — the design pass

Status: the dynamic-tables shape replaced the v1 selection workaround
2026-08-23, and the Rust/Python depth slice is ALL PASS through the
five-lane matrix. THE TRANSACTIONS VIEW JOINED THE APP 2026-08-26, the
second of the three forcing features (docs/virtualization-plan.md §6.2's
amendment: it lived in its own guest only until row windowing reached
every backend). The desktop scene is live; mobile stays declared off
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

One window, a two-column row: LEFT is the portfolio total, the book's
transaction count, the "Day tick" button and the "Transactions" button;
RIGHT is a For of account cards. Every account copy owns its name,
total, and positions TABLE (Ticker | Qty | Price | Value). The table is
a nested collection instance keyed by that account, and each copy owns
its sort indicator and order.

THE SECOND SCREEN is the transactions view (§6), one `push_entry` away.

Deliberate v1 choices, each a recorded stop short of a forced feature:

- **One table per account.** This is the dynamic-tables forcing shape:
  the nested collection is declared inside the account template and
  mutated through `positions.at(account)`.
- **No chart.** The portfolio total is a label; the canvas slice will
  replace the space above it with a value-over-time chart. The "Day
  tick" button exists partly to accumulate the series a chart will
  want.
- **A small book.** Three accounts, six tickers; the dashboard stamps
  every row it has. The book's HISTORY is the other scale entirely —
  15,000 rows behind §6's push.
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

IT ALSO POSTS THE DAY'S TRANSACTIONS (2026-08-26): one DIVIDEND per
account, appended to §6's ledger, which is what makes the two screens
one model rather than two. A dividend was the only shape available once
the tie-out was ruled — money moves, quantity does not — so the holdings
the view nets to are the same before and after a tick. The dashboard's
count line moves with them, and it moves whether or not the view is
pushed — a tick with the view closed writes to no dead collection,
which the scene pins by ticking before it ever navigates.

## §3 — the scene (tools/scenes/portfolio.steps)

Byte-frozen on the three desktop lanes, ONE SCENE FOR BOTH SCREENS. The
dashboard half reads all three tables, sorts Retirement by Value in both
directions, proves Brokerage and Savings keep an empty indicator, gives
Brokerage its own Qty sort, then ticks every price and proves both
independent sorts survive. The transactions half then pushes the view
and asserts the windowed contract there (§6), and `back` proves the
covered dashboard kept its numbers and its per-copy sorts.

Leaf targets are positional on the dashboard; each table is addressed as
`column@positions[account]` — the authored id identifies the template
node and the bracketed string-key path identifies its stamped copy. On
the pushed screen the four status labels are addressed by AUTHORED ID
(`label@count`), because their creation index sits behind every stamped
cell the dashboard made and a band decides how many of those exist.

## §4 — sequencing

1. Dynamic tables — GREEN at depth: the app + divergence scene on
   mac/linux/windows; mobile remains declared off with the packaging
   reason. The app opens no OS chrome and injects no keys, so it pools.
2. The packaging milestone (ledgered): CPython + the binding into the
   APK and the iOS bundle; the mobile legs then wire and the panes
   pass joins.
3. The remaining feature slices land in the ruled order: virtualization
   (the transactions view — DONE 2026-08-26, §6), then canvas (the
   chart).

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
  in docs/traps.md; the scene now pins the declared window size (800x600
  then, 900x600 since the transactions view joined — §6's screen carries
  two tables side by side and was proven at that width), both nested
  alignments,
  table containment, and horizontal cell edges for all three copies,
  repeated after each sort re-declaration and the live price tick.
- **A STAMPED BUTTON CANNOT BE DRIVEN BY A SCENE (2026-08-26), which is
  why the transactions view is filtered rather than opened per account.**
  The natural app shape is a "Transactions" button on each account card;
  its target would be `button@txns[brokerage]`, and the keyed arm of
  `resolve_id` answers for `column` alone in all three harness
  implementations (`if kind != K::Column { return None }` in gtk.rs and
  winui/mod.rs, `guard kind == "column"` in KayaSwiftUI.swift). WinUI
  cannot even answer the UNKEYED `button@id`: its buttons registry stores
  click tags, not controls, and the file says so. So the affordance is one
  LIVE button on the dashboard and the account is chosen inside the view
  by its filter — the same "one account's history", one screen later.
  Widening the keyed arm to every kind is a harness slice of its own
  (ledgered), not something to smuggle in behind an app.
  CLOSED 2026-09-01: that slice landed (docs/deferred.md's keyed-target
  entry) — every occurrence tag carries the table tag's node-and-keys
  layout, so all four backends resolve `kind@id[key.path]` for any
  tagged kind — and the natural shape is the shipped one: each account
  card carries its own "Transactions" button (a11y id `transactions`),
  the click arrives with the card's key and opens the view filtered to
  that account with the filter's own selection set to match, and the
  scene clicks `button@transactions[retirement]` on five lanes. The
  live dashboard button stays as the whole-book route.

## §6 — the transactions view

The third forcing feature's artifact (docs/virtualization-plan.md §5):
the whole book's history, 15,000 rows in one For, windowed by nature.
It lived in its own guest while row windowing reached only some
backends; §6.2's amendment ended that when the breadth slice landed,
and 2026-08-26 it became this app's second screen.

- **Reached by `push_entry`**, the serial navigation grammar
  (guests/python/nav.py is the conformance spelling): a "Transactions"
  button on the dashboard pushes an entry titled "Transactions", and the
  platform's own back affordance pops it. The covered dashboard is
  retained, which the scene asserts on the way back.
- **The screen is a two-column row**: LEFT the count line, the first and
  last row of what is showing, the net line, the account filter and the
  twelve most recent transactions in FILE order; RIGHT the ledger itself,
  grown, the fill-and-scroll viewport the window reports its visible
  range from.
- **The data is derived, never committed**: tools/gen-market.py writes
  guests/assets/market/transactions.csv from a spelled-out LCG, and
  check-assets re-derives every string the scene freezes about it — the
  artifact plus the guest's own POSTED — so retuning the generator
  reddens ONE gate naming this scene instead of three lanes.
- **The guest writes no windowing code**: it inserts every row it has and
  reads every row it has (docs/virtualization-plan.md §1). The screen's
  state (filter, sort) belongs to the screen: a freshly pushed view shows
  the whole book unsorted.
- **THE TWO SCREENS TIE OUT** (ruled 2026-08-26): an account's holdings
  ARE the sum of its transactions. tools/gen-market.py reads BOOK out of
  the guest by ast and generates a history that nets to it — sells never
  exceed what is held, buys never run more than one lot above the book,
  each (account, ticker) pair's LAST lot settles that pair, and the
  generator refuses itself if any pair still disagrees. CASH is a
  tradeable ticker there, flat at its anchor, because it is a book
  holding. "Day tick" posts DIVIDENDS, which move money and not quantity,
  so a tick cannot break the tie.
  The view says it out loud in `label@net`: buys minus sells over the
  rows showing, per ticker, priced at the live book. Unfiltered that is
  the six Qty cells the positions tables freeze and label#0's own money;
  filtered to one account it is that account's card and its
  "Account total:" to the byte. check-assets' C10 nets the artifact
  against BOOK, derives both lines, and refuses a net line whose money
  the dashboard never says — a tie-out asserted nowhere is not a guard.

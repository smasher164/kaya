"""The portfolio app (docs/portfolio-plan.md): the dashboard — one
positions table per account, a deterministic "Day tick", integer-cent
money — and one push away the TRANSACTIONS VIEW, the whole book's
15,000-row ledger in one For (docs/virtualization-plan.md §5, whose
§6.2 amendment retired the standalone ledger guest when the breadth
slice landed).

THE VIEW WRITES NO WINDOWING CODE AND MAKES NO PROMISES: it inserts
every row it has and reads every row it has; the band is the backend's
and the core's business.

THE TWO SCREENS TIE OUT (ruled 2026-08-26): an account's holdings ARE
the sum of its transactions, so the view's net line reproduces the
dashboard's account total to the byte. tools/gen-market.py reads BOOK
below and generates a history that nets to it.

Build the library first (cargo build), then:
    KAYA_SELFTEST=portfolio python3 guests/python/portfolio.py
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Position:
    ticker: str
    qty: str
    price: str
    value: str


@dataclass
class Account:
    name: str
    total: str


@dataclass
class Txn:
    date: str
    ticker: str
    side: str
    total: str


# The book: fixed holdings, prices in integer cents, and the tick's
# fixed per-ticker delta. Every number the scene asserts derives from
# these by arithmetic, never by observation.
#
# IT IS ALSO THE LEDGER'S BOOK: tools/gen-market.py reads BOOK out of
# this file by ast and generates a history that nets to it, so the two
# screens agree by construction (the tie-out, ruled 2026-08-26).
BOOK = {
    "brokerage": ("Brokerage", [("AAPL", 10, 18000), ("NVDA", 4, 95050), ("VTI", 6, 26025)]),
    "retirement": ("Retirement", [("BND", 20, 7210), ("VXUS", 15, 6140)]),
    "savings": ("Savings", [("CASH", 1, 50000)]),
}
TICK = {"AAPL": 250, "NVDA": -1000, "VTI": 75, "BND": -10, "VXUS": 60, "CASH": 0}
ACCOUNT_ORDER = ["brokerage", "retirement", "savings"]

# The one resolver (crates/kaya/src/assets.rs): the bytes come from the
# asset root the lane staged, never from a path this guest spells.
LEDGER = "market/transactions.csv"
HISTORY = "market/prices.csv"

# The transactions view's surface id, and the filter's options with the
# account each names. The first is "no filter", which is what "or all"
# means.
TRANSACTIONS = 7
FILTERS = [
    ("All accounts", None),
    ("Brokerage", "brokerage"),
    ("Retirement", "retirement"),
    ("Savings", "savings"),
]

# The tail the side panel keeps, in FILE order whatever the ledger is
# filtered or sorted to. Small on purpose: at 12 rows the band covers
# the whole collection and windowing is observably invisible
# (docs/virtualization-plan.md §1), which is the one place a shared
# scene can freeze a realized count.
# 8, down from 12 (the maintainer, 2026-08-30): with the fold, the
# recents and the ledger share one screen on a phone, and at 12 the
# recents card pushed the seam and the ledger's opening below the fold.
RECENT = 8

# What "Day tick" posts: the day's dividend for each account, on the day
# after the ledger's last, in the same shape read_ledger yields. A
# DIVIDEND MOVES MONEY AND NOT QUANTITY, which is what lets a tick post
# into the book without breaking the tie-out — the net line below is
# asserted after the tick, on data these rows are part of.
POSTED = [
    ("2026-08-25", "brokerage", "AAPL", "div", 0, 240),
    ("2026-08-25", "retirement", "BND", "div", 0, 620),
    ("2026-08-25", "savings", "CASH", "div", 0, 205),
]

prices = {t: cents for _, holdings in BOOK.values() for t, _, cents in holdings}
sorted_accounts = {}


def money(cents):
    """Integer cents, no thousands separator — expect_rows joins cells
    with commas (docs/portfolio-plan.md §1)."""
    return f"${cents // 100}.{cents % 100:02d}"


def read_ledger():
    with kaya.asset(LEDGER) as csv:
        lines = csv.bytes().decode("ascii").splitlines()
    out = []
    for line in lines[1:]:
        date, account, ticker, side, qty, _price, total = line.split(",")
        out.append((date, account, ticker, side, int(qty), int(total)))
    return out


def read_history():
    """The price walk: every day, every ticker. Returns the days in file
    order and each ticker's series against them."""
    with kaya.asset(HISTORY) as csv:
        lines = csv.bytes().decode("ascii").splitlines()
    days, series = [], {}
    for line in lines[1:]:
        date, ticker, cents = line.split(",")
        if not days or days[-1] != date:
            days.append(date)
        series.setdefault(ticker, []).append(int(cents))
    return days, series


txns = read_ledger()
history_days, history = read_history()

# THE CHART TIES TO THE BOOK, the ledger's tie-out one column over: the
# last day of history IS the dashboard's present, so the series the chart
# draws ends on the money label#0 shows. Asserted here rather than
# assumed, because a history that ended a few days short would draw a
# plausible chart nobody could tell was wrong (tools/gen-market.py
# refuses to write one, and check-assets holds the artifact to the same
# book).
for _ticker, _cents in prices.items():
    if history[_ticker][-1] != _cents:
        raise SystemExit(
            f"portfolio: {HISTORY} ends {_ticker} at {history[_ticker][-1]} "
            f"and the book prices it at {_cents} — the chart would end "
            "somewhere this dashboard does not; regenerate with "
            "`python3 tools/gen-market.py --ensure`")


def account_total(account):
    _, holdings = BOOK[account]
    return sum(qty * prices[t] for t, qty, _ in holdings)


def portfolio_total():
    return sum(account_total(a) for a in ACCOUNT_ORDER)


def position(account, ticker, qty):
    return Position(
        ticker=ticker,
        qty=str(qty),
        price=money(prices[ticker]),
        value=money(qty * prices[ticker]),
    )


def fill_positions(account):
    _, holdings = BOOK[account]
    table = positions.at(account)
    for ticker, qty, _ in holdings:
        table.insert(ticker, position(account, ticker, qty))


def apply_order(account, column, descending):
    table = positions.at(account)
    _, holdings = BOOK[account]
    qty_of = {ticker: qty for ticker, qty, _ in holdings}
    key_of_column = {
        0: lambda entry: entry[0],
        1: lambda entry: qty_of[entry[0]],
        2: lambda entry: prices[entry[0]],
        3: lambda entry: qty_of[entry[0]] * prices[entry[0]],
    }[column]
    entries = table.items()
    entries.sort(key=key_of_column, reverse=descending)
    for key, _ in entries:
        table.move_to_end(key)
    indicator = kaya.Sort.desc(column) if descending else kaya.Sort.asc(column)
    table.set_columns("Ticker", "Qty", "Price", "Value", sort=indicator)


def on_positions_sort(account, column):
    current = sorted_accounts.get(account)
    descending = current is not None and current[0] == column and not current[1]
    sorted_accounts[account] = (column, descending)
    apply_order(account, column, descending)


# ---------------------------------------------------------------- the
# chart (docs/canvas-plan.md §10). APP ARITHMETIC, NOT A CORE SURFACE:
# everything below is ordinary python over the price history, spoken to
# the core as the op vocabulary of §3.3 in the paint roles of §3.4.
#
# THE CHART IS AT ITS NATURAL SIZE — no grow, in a hugging column — where
# `scale` (the default, declared by writing nothing) and every other
# policy coincide, because an ungrown canvas's track IS its viewbox
# (docs/canvas-plan.md §3.2.1). The mark below is the other half of that
# ruling: the one canvas here whose track is NOT its viewbox.
CHART_BOX = (280.0, 180.0)
# The plot rect inside the box: a left gutter for the money labels, a
# bottom gutter for the dates. INSET ON PURPOSE — a drawing that filled
# its box reads 0,0,100,100 in expect_drawing whatever the transform did
# (docs/canvas-plan.md §7.2).
PLOT = (44.0, 12.0, 274.0, 150.0)
CHART_DAYS = 90
# Half the last point's marker square.
MARK = 2.5

# THE DRAWN MARK beside the dashboard's title, `fixed`'s forcing artifact
# (docs/canvas-plan.md §3.2.1, ruling 3): this drawing is 28x28 and does
# not adapt to whatever track layout hands it. Ungrown because a title
# chip is its natural size by design — where track and viewbox coincide,
# every policy agrees, and `expect_raster` cannot see this declaration
# (the scene's comment carries the measurement); the declaration is the
# app saying the true thing about the drawing, and its forcing assertion
# rides tools/scenes/sizepolicy.steps, whose canvases grow.
MARK_BOX = (28.0, 28.0)
# The mark's rising line in MARK_BOX units, closed down to a baseline for
# the filled area under it — the chart's own grammar at glyph size.
MARK_LINE = [(2.0, 13.0), (9.0, 7.0), (16.0, 11.0), (26.0, 3.0)]
MARK_AREA = MARK_LINE + [(26.0, 26.0), (2.0, 26.0)]


def axis_band(low, high):
    """The gridline floor, ceiling and step in cents: the smallest 1-2-5
    step that covers the range in at most four intervals, so every
    gridline is a round number of dollars whatever the window holds."""
    for step in (10_000, 20_000, 25_000, 50_000, 100_000,
                 200_000, 250_000, 500_000, 1_000_000):
        floor = low // step * step
        ceiling = -(-high // step) * step
        if ceiling - floor <= 4 * step:
            return floor, ceiling, step
    raise SystemExit(
        f"portfolio: no 1-2-5 step covers {low}..{high} in four intervals")


def value_series():
    """The book valued at each of the last CHART_DAYS days' prices,
    oldest first. THE LAST POINT IS TODAY, priced from the live book, so
    a tick moves the chart's right edge and the dashboard's total by the
    same arithmetic."""
    qty = {t: q for _, holdings in BOOK.values() for t, q, _ in holdings}
    days = history_days[-CHART_DAYS:]
    first = len(history_days) - CHART_DAYS
    values = [sum(q * history[t][first + i] for t, q in qty.items())
              for i in range(CHART_DAYS)]
    values[-1] = portfolio_total()
    return days, values


def chart_summary_text(days, values):
    """What a screen reader is told, and the chart's tie-out said out
    loud: a drawing is pixels, so the numbers live in the widget's
    accessible name (docs/canvas-plan.md §9)."""
    return (f"Portfolio value, {len(days)} days to {days[-1]}, "
            f"{money(min(values))} to {money(max(values))}, "
            f"now {money(values[-1])}")


def draw_chart():
    """Re-declare the whole drawing. One record replaces it atomically —
    never a patch (docs/canvas-plan.md §2.1)."""
    days, values = value_series()
    floor, ceiling, step = axis_band(min(values), max(values))
    left, top, right, bottom = PLOT

    def x_at(i):
        return left + (right - left) * i / (len(values) - 1)

    def y_at(cents):
        return bottom - (bottom - top) * (cents - floor) / (ceiling - floor)

    points = [(x_at(i), y_at(v)) for i, v in enumerate(values)]
    gridlines = list(range(floor, ceiling + 1, step))
    chart_summary.set(chart_summary_text(days, values))
    with chart.draw() as d:
        # The plot ground: the PLOT RECT, not the box, so the gutters
        # stay transparent and the ink bounds are the figure's.
        d.move_to(left, top).line_to(right, top)
        d.line_to(right, bottom).line_to(left, bottom).close()
        d.fill("ground")
        for cents in gridlines:
            d.move_to(left, y_at(cents)).line_to(right, y_at(cents))
        d.stroke("grid", width=1)
        # The area under the series, closed down to the plot's baseline.
        d.polyline(points).line_to(right, bottom).line_to(left, bottom)
        d.close().fill("series_fill")
        d.polyline(points).stroke("series", width=1.5)
        # The axis is an L: the money edge and the date edge, drawn over
        # the fill so the plot has a boundary the eye can find.
        d.move_to(left, top).line_to(left, bottom).line_to(right, bottom)
        d.stroke("axis", width=1)
        # Today, marked: the one point the dashboard's own total names.
        # CLAMPED WHOLLY INSIDE THE PLOT, never centred on its edge —
        # the last point IS the right edge, so an uncentred box is what
        # keeps the marker off the window's own ground (ruled from the
        # first capture, 2026-08-27).
        x = min(max(points[-1][0], left + MARK), right - MARK)
        y = min(max(points[-1][1], top + MARK), bottom - MARK)
        d.move_to(x - MARK, y - MARK).line_to(x + MARK, y - MARK)
        d.line_to(x + MARK, y + MARK).line_to(x - MARK, y + MARK)
        d.close().fill("series")
        # kaya's own embedded face (`""`), so the labels draw on a lane
        # whose asset root staged no typeface (docs/canvas-plan.md §4.2).
        d.font(9)
        for cents in gridlines:
            d.text(left - 4, y_at(cents), f"${cents // 100}",
                   paint="axis", align="end", baseline="middle")
        d.text(left, bottom + 5, days[0],
               paint="axis", align="start", baseline="top")
        d.text(right, bottom + 5, days[-1],
               paint="axis", align="end", baseline="top")


def tick():
    for ticker, delta in TICK.items():
        prices[ticker] += delta
    for account in ACCOUNT_ORDER:
        table = positions.at(account)
        _, holdings = BOOK[account]
        for ticker, qty, _ in holdings:
            table.update(ticker, position(account, ticker, qty))
        accounts.patch(account, total=f"Account total: {money(account_total(account))}")
        if account in sorted_accounts:
            apply_order(account, *sorted_accounts[account])
    portfolio_value.set(f"Portfolio: {money(portfolio_total())}")
    # The chart's right edge IS the total above it, so it is redrawn from
    # the same prices in the same transaction.
    draw_chart()
    txns.extend(POSTED)
    book_size.set(f"Transactions: {len(txns)}")
    # THE VIEW IS ONLY THERE WHILE IT IS PUSHED: its collections die with
    # the popped entry, and a refresh into them would write to widgets
    # nothing holds. The scene ticks with the view closed on purpose.
    if screen:
        refresh()


# ---------------------------------------------------------------- the
# transactions view. `screen` holds its handles while it is pushed and
# is empty while it is not.
screen = {}
view = {"account": None, "sort": None}


def key_of(index):
    """A transaction has no identity of its own — no column of this CSV
    is unique — so the key is its position in the file, minted here.
    A STRING key, not the i64 insert_fresh would mint: the scene names
    keys in `scroll_to_row` and in `kind@id[key]` targets, and the
    untyped segment of that grammar matches string keys only
    (docs/portfolio-plan.md §5)."""
    return f"t{index:05d}"


def cells(row):
    date, _account, ticker, side, _qty, total = row
    return Txn(date=date, ticker=ticker, side=side, total=money(total))


def edge(label, row):
    if row is None:
        return f"{label} —"
    date, _account, ticker, side, _qty, total = row
    return f"{label} {date} {ticker} {side} {money(total)}"


def net_line(rows):
    """THE TIE-OUT, said out loud: buys minus sells over the rows showing,
    per ticker, priced at the book's live prices. Filtered to one account
    it is that account's holdings and its dashboard total, to the byte;
    unfiltered it is the whole book and the portfolio total. Dividends
    carry no quantity, so a tick cannot move it (docs/portfolio-plan.md
    §6)."""
    net = {}
    for _date, _account, ticker, side, qty, _total in rows:
        if side == "buy":
            net[ticker] = net.get(ticker, 0) + qty
        elif side == "sell":
            net[ticker] = net.get(ticker, 0) - qty
    held = {t: q for t, q in net.items() if q}
    if not held:
        return "net — = $0.00"
    value = sum(q * prices[t] for t, q in held.items())
    return ("net " + ", ".join(f"{t} {held[t]}" for t in sorted(held))
            + f" = {money(value)}")


def selected():
    """The rows to show, in the order to show them, keyed."""
    account = view["account"]
    keyed = [(key_of(i), row) for i, row in enumerate(txns)
             if account is None or row[1] == account]
    if view["sort"] is not None:
        column, descending = view["sort"]
        of = (lambda kr: kr[1][0], lambda kr: kr[1][2],
              lambda kr: kr[1][3], lambda kr: kr[1][5])[column]
        # The key breaks ties, so the sorted order is a function of the
        # data alone — a stable sort would make it a function of the
        # order the rows happened to be in, which no scene can freeze.
        keyed.sort(key=lambda kr: (of(kr), kr[0]), reverse=descending)
    return keyed


def sync(collection, held, want):
    """Make `collection` hold exactly `want`, in that order.

    Removals and insertions first, and the reordering ONLY if what they
    left is not already the wanted order: narrowing a filter preserves
    relative order, and a table that re-sorted itself for nothing would
    cost one move record per row for no observable change.
    """
    wanted = {k for k, _ in want}
    surviving = [k for k in held if k in wanted]
    for k in held:
        if k not in wanted:
            collection.remove(k)
    have = set(held)
    for k, row in want:
        if k not in have:
            collection.insert(k, cells(row))
            surviving.append(k)
    order = [k for k, _ in want]
    if surviving != order:
        for k in order:
            collection.move_to_end(k)
    held[:] = order


def refresh():
    want = selected()
    # The keys each collection holds, in order. The guest's own
    # bookkeeping, never a mirror read: items() is refused at record
    # time, and the whole point of this view is that reading 15,000 rows
    # costs nothing.
    sync(screen["ledger"], screen["in_ledger"], want)
    sync(screen["recent"], screen["in_recent"],
         [(key_of(i), row) for i, row in enumerate(txns)][-RECENT:])
    screen["count"].set(f"{len(want)} of {len(txns)} transactions")
    screen["first"].set(edge("first", want[0][1] if want else None))
    screen["last"].set(edge("last", want[-1][1] if want else None))
    screen["net"].set(net_line(row for _key, row in want))


def on_filter(index):
    view["account"] = FILTERS[index][1]
    refresh()


def on_ledger_sort(column):
    current = view["sort"]
    descending = current is not None and current[0] == column and not current[1]
    view["sort"] = (column, descending)
    refresh()
    indicator = kaya.Sort.desc(column) if descending else kaya.Sort.asc(column)
    screen["ledger"].set_columns("Date", "Ticker", "Side", "Total", sort=indicator)


def closed_transactions():
    screen.clear()


def open_transactions():
    # A freshly opened view shows the whole book, unsorted: the state
    # belongs to the screen, and the screen is new.
    view["account"] = None
    view["sort"] = None
    with app.push_entry(TRANSACTIONS, title="Transactions",
                        on_popped=closed_transactions):
        count_line = kaya.signal("")
        first_line = kaya.signal("")
        last_line = kaya.signal("")
        net_signal = kaya.signal("")
        with kaya.row(stack_below=700):
            # A HUGGING SUMMARY, THEN THE ONE GROWN TABLE — the stacked
            # fold's shape (docs/adaptive-layout-plan.md D7). Side by side
            # on a desktop these are two columns; stacked on a phone the
            # core folds the summary into the ledger's viewport, one
            # scroll, the summary scrolling away above row 0. The app
            # declares nothing extra: the fold is derived from this shape.
            with kaya.column(align="stretch") as summary:
                summary.a11y_id("summary")
                kaya.label(bind=count_line).a11y_id("count")
                kaya.label(bind=first_line).a11y_id("first")
                kaya.label(bind=last_line).a11y_id("last")
                kaya.label(bind=net_signal).a11y_id("net")
                kaya.select([name for name, _ in FILTERS], selected=0,
                            on_select=on_filter)  # select#0
                recent = kaya.collection(Txn)
                # UNGROWN: a summary table hugs its rows (the empty-row
                # ruling, docs/tables-plan.md).
                for row in recent.columns("Date", "Ticker", "Side", "Total",
                                          a11y_id="recent"):
                    with kaya.row():
                        kaya.label(bind=row.date)
                        kaya.label(bind=row.ticker)
                        kaya.label(bind=row.side)
                        kaya.label(bind=row.total)
            ledger = kaya.collection(Txn)
            # GROWN: this one is the fill-and-scroll viewport the
            # window reports its visible range from — and the row's
            # direct child, which is what the fold rule reads.
            for row in ledger.columns("Date", "Ticker", "Side", "Total",
                                      on_sort=on_ledger_sort, grow=1,
                                      a11y_id="ledger"):
                with kaya.row():
                    kaya.label(bind=row.date)
                    kaya.label(bind=row.ticker)
                    kaya.label(bind=row.side)
                    kaya.label(bind=row.total)
        screen.update(count=count_line, first=first_line, last=last_line,
                      net=net_signal, recent=recent, ledger=ledger,
                      in_recent=[], in_ledger=[])
        refresh()


app = kaya.App()

with app.window(title="portfolio", width=900, height=600):
    portfolio_value = kaya.signal(f"Portfolio: {money(portfolio_total())}")
    book_size = kaya.signal(f"Transactions: {len(txns)}")
    # THE DASHBOARD'S TWO COLUMNS STACK ON A PHONE
    # (docs/adaptive-layout-plan.md D3): side by side they are ~900 points
    # wide, so on a 393-point screen the detail column ran off the right
    # edge — SwiftUI clipped it, Compose gave it a zero-width track and the
    # tables recorded no geometry at all. One keyword, evaluated in the
    # core against the window's own width.
    # THE SCREEN SCROLLS WHEN IT DOES NOT FIT (2026-08-29). Stacked on
    # a phone this dashboard is 586 points of account tables in a
    # 259-point track, so Savings was not below the fold — it was
    # UNREACHABLE, with no gesture that could bring it back. A desktop
    # window fits the content and a viewport that fits does not
    # scroll, so one declaration serves every platform.
    with kaya.scroll(grow=1):
        with kaya.row(stack_below=700):
            with kaya.column():
                # THE DRAWN MARK, inline with the title (the placement ruling,
                # 2026-08-28): a row hugs its content, so the chip can take no
                # share of the column's leftover — as a bare column child it
                # did, floating centred in empty space with the chart pushed
                # to the column's bottom and every assertion green.
                with kaya.row(align="center"):
                    mark = kaya.canvas(MARK_BOX, fixed=True)
                    mark.a11y_id("mark").a11y_label("kaya portfolio mark")
                    with mark.draw() as d:
                        # The ground mound under the translucent series fill
                        # is what makes the centre opaque — expect_ink samples
                        # hundredths of the canvas's own box, and a
                        # translucent probe point would read the compositor's
                        # ground instead of the palette's.
                        d.polyline(MARK_AREA).close().fill("ground")
                        d.polyline(MARK_AREA).close().fill("series_fill")
                        d.polyline(MARK_LINE).stroke("series", width=2)
                    kaya.label(bind=portfolio_value)  # label#0
                kaya.label(bind=book_size)  # label#1
                # THE CHART, beside the account tables in a column that hugs,
                # so the canvas is laid out at the natural size its viewbox
                # declares. Its numbers are spoken through the accessible
                # name — a drawing is an image to every platform's
                # accessibility tree (docs/canvas-plan.md §9).
                # DECLARED WITH THE REAL TEXT, never "": an empty a11y label
                # is refused at the tx (crates/kaya/src/scene.rs), and the
                # summary is computable here — draw_chart() recomputes the
                # same string from the same series on the next line.
                chart_summary = kaya.signal(chart_summary_text(*value_series()))
                chart = kaya.canvas(CHART_BOX)
                chart.a11y_id("chart").a11y_label(chart_summary)
                draw_chart()
                kaya.button("Day tick", on_click=tick)  # button#0
                kaya.button("Transactions", on_click=open_transactions)  # button#1
            accounts = kaya.collection(Account)
            with kaya.column(grow=1, align="stretch") as detail:  # the detail column
                detail.a11y_id("detail")
                for account in accounts.rows(
                    align="stretch", a11y_id="accounts",
                ):
                    with kaya.column(align="stretch"):
                        # The account's heading/table/caption triple: on a
                        # grouped screen (iOS) these are the section's
                        # header and footer seats; everywhere else the
                        # platform's heading and footnote text tiers, and
                        # the AX heading trait assistive users skim by.
                        kaya.heading(bind=account.name)
                        positions = kaya.collection(Position)
                        # UNGROWN since the empty-row ruling: a summary
                        # table hugs its rows (docs/tables-plan.md); grow is
                        # the fill-and-scroll opt-in this dashboard no longer
                        # wants.
                        for item in positions.columns(
                            "Ticker", "Qty", "Price", "Value",
                            on_sort=on_positions_sort, a11y_id="positions",
                        ):
                            with kaya.row():
                                kaya.label(bind=item.ticker)
                                kaya.label(bind=item.qty)
                                kaya.label(bind=item.price)
                                kaya.label(bind=item.value)
                        kaya.caption(bind=account.total)
    for account in ACCOUNT_ORDER:
        name, _ = BOOK[account]
        accounts.insert(
            account,
            Account(name=name, total=f"Account total: {money(account_total(account))}"),
        )
    for account in ACCOUNT_ORDER:
        fill_positions(account)

sys.exit(app.run())

"""The portfolio app's transactions view (docs/portfolio-plan.md §0's
third forcing feature, docs/virtualization-plan.md §5's uniform scene):
the market ledger's 15,000 rows in ONE For, windowed by nature.

THIS GUEST WRITES NO WINDOWING CODE AND MAKES NO PROMISES — there is
nothing to declare and no callback to implement (plan §1). It inserts
every row it has, reads every row it has, and the band is the backend's
and the core's business.

WHY ITS OWN FILE AND NOT A SECOND SCREEN IN portfolio.py: a Python
guest serves one scene, and a 15,000-row For inside portfolio.py would
be stamped by the portfolio scene on every lane — including the two
whose backends have no window yet, where GTK crosses X11's 32,767px
ceiling at ~1,361 rows. The dashboard's scene stays untouched and green
while the breadth slice lands.

Build the library first (cargo build), then:
    KAYA_SELFTEST=ledger python3 guests/python/ledger.py
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Txn:
    date: str
    ticker: str
    side: str
    total: str


# The one resolver (crates/kaya/src/assets.rs): the bytes come from the
# asset root the lane staged, never from a path this guest spells.
LEDGER = "market/transactions.csv"

# The filter's options and the account each names. The first is "no
# filter", which is what "or all" means.
FILTERS = [
    ("All accounts", None),
    ("Brokerage", "brokerage"),
    ("Retirement", "retirement"),
    ("Savings", "savings"),
]

# The tail the side panel keeps, in FILE order whatever the ledger is
# filtered or sorted to. Small on purpose: at 12 rows the band covers
# the whole collection and windowing is observably invisible (plan §1),
# which is the one place a shared scene can freeze a realized count.
RECENT = 12

# What "Day tick" posts: one transaction per account on the day after
# the ledger's last, at the dashboard's own book prices and quantities
# (guests/python/portfolio.py's BOOK), so the three totals are the
# dashboard's asserted values.
POSTED = [
    ("2026-08-25", "brokerage", "AAPL", "buy", 10, 18000),
    ("2026-08-25", "retirement", "BND", "buy", 20, 7210),
    ("2026-08-25", "savings", "VTI", "buy", 6, 26025),
]


def money(cents):
    """Integer cents, no thousands separator — expect_rows joins cells
    with commas (docs/portfolio-plan.md §1)."""
    return f"${cents // 100}.{cents % 100:02d}"


def read_ledger():
    with kaya.asset(LEDGER) as csv:
        lines = csv.bytes().decode("ascii").splitlines()
    out = []
    for line in lines[1:]:
        date, account, ticker, side, _qty, _price, total = line.split(",")
        out.append((date, account, ticker, side, int(total)))
    return out


txns = read_ledger()


def key_of(index):
    """A transaction has no identity of its own — no column of this CSV
    is unique — so the key is its position in the file, minted here.
    A STRING key, not the i64 insert_fresh would mint: the scene names
    keys in `scroll_to_row` and in `kind@id[key]` targets, and the
    untyped segment of that grammar matches string keys only
    (docs/portfolio-plan.md §5)."""
    return f"t{index:05d}"


def cells(row):
    date, _account, ticker, side, total = row
    return Txn(date=date, ticker=ticker, side=side, total=money(total))


def edge(label, row):
    if row is None:
        return f"{label} —"
    date, _account, ticker, side, total = row
    return f"{label} {date} {ticker} {side} {money(total)}"


# What the view is showing: which account (None = all) and which column
# is sorted, the table.py idiom one collection over.
view = {"account": None, "sort": None}
# The keys each collection holds, in order. The guest's own bookkeeping,
# never a mirror read: items() is refused at record time, and the whole
# point of this scene is that reading 15,000 rows costs nothing.
in_ledger = []
in_recent = []


def selected():
    """The rows to show, in the order to show them, keyed."""
    account = view["account"]
    keyed = [(key_of(i), row) for i, row in enumerate(txns)
             if account is None or row[1] == account]
    if view["sort"] is not None:
        column, descending = view["sort"]
        of = (lambda kr: kr[1][0], lambda kr: kr[1][2],
              lambda kr: kr[1][3], lambda kr: kr[1][4])[column]
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
    sync(ledger, in_ledger, want)
    sync(recent, in_recent, [(key_of(i), row)
                             for i, row in enumerate(txns)][-RECENT:])
    count_line.set(f"{len(want)} of {len(txns)} transactions")
    first_line.set(edge("first", want[0][1] if want else None))
    last_line.set(edge("last", want[-1][1] if want else None))


def on_filter(index):
    view["account"] = FILTERS[index][1]
    refresh()


def on_sort(column):
    current = view["sort"]
    descending = current is not None and current[0] == column and not current[1]
    view["sort"] = (column, descending)
    refresh()
    indicator = kaya.Sort.desc(column) if descending else kaya.Sort.asc(column)
    ledger.set_columns("Date", "Ticker", "Side", "Total", sort=indicator)


def tick():
    for date, account, ticker, side, qty, price in POSTED:
        txns.append((date, account, ticker, side, qty * price))
    refresh()


app = kaya.App()

with app.window(title="ledger", width=900, height=600):
    count_line = kaya.signal("")
    first_line = kaya.signal("")
    last_line = kaya.signal("")
    with kaya.row():
        with kaya.column(align="stretch"):
            kaya.label(bind=count_line)  # label#0
            kaya.label(bind=first_line)  # label#1
            kaya.label(bind=last_line)  # label#2
            kaya.select([name for name, _ in FILTERS], selected=0,
                        on_select=on_filter)  # select#0
            kaya.button("Day tick", on_click=tick)  # button#0
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
        with kaya.column(grow=1, align="stretch"):
            ledger = kaya.collection(Txn)
            # GROWN: this one is the fill-and-scroll viewport the window
            # reports its visible range from.
            for row in ledger.columns("Date", "Ticker", "Side", "Total",
                                      on_sort=on_sort, grow=1,
                                      a11y_id="ledger"):
                with kaya.row():
                    kaya.label(bind=row.date)
                    kaya.label(bind=row.ticker)
                    kaya.label(bind=row.side)
                    kaya.label(bind=row.total)
    refresh()

sys.exit(app.run())

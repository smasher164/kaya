"""The portfolio dashboard, v1 skeleton (docs/portfolio-plan.md): the
second forcing app, in Python. One table driven by account selection —
the repopulation handler below is exactly the code the dynamic-tables
landing deletes — a deterministic "Day tick", and money as integer
cents so the byte-frozen scene asserts exact strings.

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


# The book: fixed holdings, prices in integer cents, and the tick's
# fixed per-ticker delta. Every number the scene asserts derives from
# these by arithmetic, never by observation.
BOOK = {
    "brokerage": ("Brokerage", [("AAPL", 10, 18000), ("NVDA", 4, 95050), ("VTI", 6, 26025)]),
    "retirement": ("Retirement", [("BND", 20, 7210), ("VXUS", 15, 6140)]),
    "savings": ("Savings", [("CASH", 1, 50000)]),
}
TICK = {"AAPL": 250, "NVDA": -1000, "VTI": 75, "BND": -10, "VXUS": 60, "CASH": 0}
ACCOUNT_ORDER = ["brokerage", "retirement", "savings"]

prices = {t: cents for _, holdings in BOOK.values() for t, _, cents in holdings}
state = {"account": "brokerage", "sorted": None}


def money(cents):
    return f"${cents // 100}.{cents % 100:02d}"


def account_total(account):
    _, holdings = BOOK[account]
    return sum(qty * prices[t] for t, qty, _ in holdings)


def portfolio_total():
    return sum(account_total(a) for a in ACCOUNT_ORDER)


def fill_positions():
    """Writes only — legal at build time, where Python's mirror-read
    guard forbids collection reads (the window-block strictness)."""
    _, holdings = BOOK[state["account"]]
    for ticker, qty, _ in holdings:
        positions.insert(
            ticker,
            Position(
                ticker=ticker,
                qty=str(qty),
                price=money(prices[ticker]),
                value=money(qty * prices[ticker]),
            ),
        )
    positions.set_columns("Ticker", "Qty", "Price", "Value")


def repopulate():
    """The selected account's rows, rebuilt — the workaround for the
    fenced dynamic-tables shape (plan §1): one collection, its contents
    swapped on selection, the sort indicator reset with them. HANDLERS
    ONLY: the clearing loop reads the mirror."""
    for key, _ in positions.items():
        positions.remove(key)
    state["sorted"] = None
    fill_positions()


def refresh_labels():
    name, _ = BOOK[state["account"]]
    account_name.set(name)
    account_value.set(f"Account total: {money(account_total(state['account']))}")
    portfolio_value.set(f"Portfolio: {money(portfolio_total())}")


def select(key):
    state["account"] = key
    repopulate()
    refresh_labels()


def on_sort(column):
    current = state["sorted"]
    descending = current is not None and current[0] == column and not current[1]
    state["sorted"] = (column, descending)
    _, holdings = BOOK[state["account"]]
    qty_of = {t: q for t, q, _ in holdings}
    # Numeric keys for numeric columns — cents and counts, never the
    # money string (plan §3).
    key_of = {
        0: lambda e: e[0],
        1: lambda e: qty_of[e[0]],
        2: lambda e: prices[e[0]],
        3: lambda e: qty_of[e[0]] * prices[e[0]],
    }[column]
    entries = positions.items()
    entries.sort(key=lambda e: key_of(e), reverse=descending)
    for key, _ in entries:
        positions.move_to_end(key)
    indicator = kaya.Sort.desc(column) if descending else kaya.Sort.asc(column)
    positions.set_columns("Ticker", "Qty", "Price", "Value", sort=indicator)


def tick():
    for ticker, delta in TICK.items():
        prices[ticker] += delta
    repopulate()
    refresh_labels()


app = kaya.App()

with app.window(title="portfolio"):
    portfolio_value = kaya.signal(f"Portfolio: {money(portfolio_total())}")
    account_name = kaya.signal("Brokerage")
    account_value = kaya.signal(f"Account total: {money(account_total('brokerage'))}")
    with kaya.row():
        with kaya.column():
            kaya.label(bind=portfolio_value)  # label#0
            kaya.button("Day tick", on_click=tick)  # button#0
            accounts = kaya.collection(Position)  # name field only; a button per row
            for row in accounts:  # column#1 (the accounts For)
                with kaya.row():
                    # A stamped handler's first arguments are the copy's
                    # keys — the keys ARE the noun.
                    kaya.button(bind=row.ticker, on_click=select)
        # grow: the table's own grow divides THIS column's leftover, and
        # a hugging column has none; stretch: align defaults to start,
        # under which the table hugs the widest label's breadth and
        # clips its columns (tables-plan §8's class: every model
        # observable green, only pixels disagree).
        with kaya.column(grow=1, align="stretch") as detail:  # the detail column
            detail.a11y_id("detail")
            kaya.label(bind=account_name)  # label#1
            positions = kaya.collection(Position)
            # The table IS the For (docs/tables-plan.md); a table is a
            # viewport, so the scene says it fills (grow).
            # a11y_id is the harness's stable handle (column@positions)
            # AND the platform automation key — one authored prop.
            for item in positions.columns(
                "Ticker", "Qty", "Price", "Value",
                on_sort=on_sort, grow=1, a11y_id="positions",
            ):
                with kaya.row():
                    kaya.label(bind=item.ticker)
                    kaya.label(bind=item.qty)
                    kaya.label(bind=item.price)
                    kaya.label(bind=item.value)
            kaya.label(bind=account_value)  # label#2
    # Inserts after every declaration, so the stamped account buttons
    # index AFTER the live tick button: button#0 tick, then #1..#3 in
    # ACCOUNT_ORDER.
    for account in ACCOUNT_ORDER:
        name, _ = BOOK[account]
        accounts.insert(account, Position(ticker=name, qty="", price="", value=""))
    fill_positions()

sys.exit(app.run())

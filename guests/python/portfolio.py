"""The portfolio dashboard (docs/portfolio-plan.md): one positions table
per account, a deterministic "Day tick", and integer-cent money so the
byte-frozen scene asserts exact strings.

The app's other screen is guests/python/ledger.py — the transactions
view over guests/assets/market/transactions.csv, which is where row
windowing is forced. It is a separate guest because a Python guest
serves one scene and a 15,000-row For here would be stamped by THIS
scene on every lane.

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
sorted_accounts = {}


def money(cents):
    return f"${cents // 100}.{cents % 100:02d}"


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
    key_of = {
        0: lambda entry: entry[0],
        1: lambda entry: qty_of[entry[0]],
        2: lambda entry: prices[entry[0]],
        3: lambda entry: qty_of[entry[0]] * prices[entry[0]],
    }[column]
    entries = table.items()
    entries.sort(key=key_of, reverse=descending)
    for key, _ in entries:
        table.move_to_end(key)
    indicator = kaya.Sort.desc(column) if descending else kaya.Sort.asc(column)
    table.set_columns("Ticker", "Qty", "Price", "Value", sort=indicator)


def on_sort(account, column):
    current = sorted_accounts.get(account)
    descending = current is not None and current[0] == column and not current[1]
    sorted_accounts[account] = (column, descending)
    apply_order(account, column, descending)


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


app = kaya.App()

with app.window(title="portfolio", width=800, height=600):
    portfolio_value = kaya.signal(f"Portfolio: {money(portfolio_total())}")
    with kaya.row():
        with kaya.column():
            kaya.label(bind=portfolio_value)  # label#0
            kaya.button("Day tick", on_click=tick)  # button#0
        accounts = kaya.collection(Account)
        with kaya.column(grow=1, align="stretch") as detail:  # the detail column
            detail.a11y_id("detail")
            for account in accounts.rows(
                align="stretch", a11y_id="accounts",
            ):
                with kaya.column(align="stretch"):
                    kaya.label(bind=account.name)
                    positions = kaya.collection(Position)
                    # UNGROWN since the empty-row ruling: a summary
                    # table hugs its rows (docs/tables-plan.md); grow is
                    # the fill-and-scroll opt-in this dashboard no longer
                    # wants.
                    for item in positions.columns(
                        "Ticker", "Qty", "Price", "Value",
                        on_sort=on_sort, a11y_id="positions",
                    ):
                        with kaya.row():
                            kaya.label(bind=item.ticker)
                            kaya.label(bind=item.qty)
                            kaya.label(bind=item.price)
                            kaya.label(bind=item.value)
                    kaya.label(bind=account.total)
    for account in ACCOUNT_ORDER:
        name, _ = BOOK[account]
        accounts.insert(
            account,
            Account(name=name, total=f"Account total: {money(account_total(account))}"),
        )
    for account in ACCOUNT_ORDER:
        fill_positions(account)

sys.exit(app.run())

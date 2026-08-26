"""The bench row's four cells, from a counter.

ONE SOURCE: the guest stamps the rows and the driver builds the harness
expectation from the same call, so a formula change cannot make the
assertion disagree with the data. The formula is byte-identical to the
2026-08-24 mac rig's, which is what keeps today's numbers comparable to
the baselines in docs/measurements/README.md.
"""


def cells(i):
    return (
        "2026-%02d-%02d" % (((i * 4) % 12) + 1, ((i * 7) % 28) + 1),
        "TK%03d" % (i % 500),
        "BUY" if i % 2 == 0 else "SELL",
        "%.2f" % (i * 0.37 + 1.0),
    )

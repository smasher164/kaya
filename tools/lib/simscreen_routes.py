"""docs/traps.md, the iOS media_screen entry: the host's screenshot read is a
header and one pixel, a guest takes only its own ask's answer, and a watcher
that keeps a guest waiting says where the time went. No scene sees any of it
until a loaded host runs past the guest's 30 s bound."""

import re

from kaya_gate import ROOT

READER = "tools/lib/simscreen.py"
RUNSIM = "tools/ios/run-sim.py"
SWIFT = "swift/KayaSwiftUI.swift"
RUNSIM_HOLDS = [
    "SCREEN_MISREADS = simscreen.self_test()",
    'die("run-sim: tools/lib/simscreen.py misreads a screenshot: "',
    '"--type=bmp", str(shot)], SCREEN_CAPTURE_BOUND)',
    "hexed, err = simscreen.screen_pixel(f, int(parts[1]), int(parts[2]))",
    'rid, _, verb = verb.partition(" ")',
    '("ok" if rc == 0 else "err") + (f" {rid}" if rid else "")',
    "account = Account(doing, rid, verb, queued)",
    "f\"parts={account.log()} \"",
]
ASK_HOLDS = [
    'guard fm.createFile(atPath: requestPath, contents: Data("\\(id) \\(verb)".utf8)) else {',
    "guard head.count == 2, head[1] == id else { continue }",
    "return (head[0] == \"ok\", Array(lines.dropFirst()))",
    "let doing = (fm.contents(atPath: doingPath)",
]


def reader_findings(source):
    space = {"__name__": "simscreen_shadow"}
    exec(compile(source, READER, "exec"), space)  # noqa: S102
    return [f"{READER}: {line}" for line in space["self_test"]()]


def findings(sources):
    bad = reader_findings(sources[READER])
    for needle in RUNSIM_HOLDS:
        if needle not in sources[RUNSIM]:
            bad.append(f"{RUNSIM} lacks {needle}")
    if "decode_png" in sources[RUNSIM]:
        bad.append(f"{RUNSIM} decodes a whole PNG (decode_png): 1.5 s idle and 17 s "
                   f"under load across four watchers sharing one GIL")
    ask = re.search(r"\n        static func ask\(_ verb: String.*?\n        \}\n", sources[SWIFT], re.S)
    if ask is None:
        bad.append(f"{SWIFT}: KayaSimdrive.ask not found")
    else:
        for needle in ASK_HOLDS:
            if needle not in ask.group(0):
                bad.append(f"{SWIFT}: KayaSimdrive.ask lacks {needle}")
    return bad


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in (READER, RUNSIM, SWIFT)}
    g.counted("simscreen clauses held", len(RUNSIM_HOLDS) + len(ASK_HOLDS) + 2, floor=14)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        (READER, "the whole image read", r"px = f\.read\(4\)", "px = f.read()[:4]", "never the image"),
        (READER, "no sRGB refusal", r"if hsize < 108 or space != SRGB:", "if hsize < 108:",
         "no sRGB colour space was read"),
        (READER, "a bottom-up BMP read top-down", r"row = y if h < 0 else rows - 1 - y", "row = y",
         "bottom-up BMP's pixel"),
        (READER, "the channels swapped", r"\(px\[2\], px\[1\], px\[0\]\)", "(px[0], px[1], px[2])",
         "wanted C83C1E"),
        (RUNSIM, "the reader's self-test not run", r"SCREEN_MISREADS = simscreen\.self_test\(\)",
         "SCREEN_MISREADS = []", "lacks SCREEN_MISREADS"),
        (RUNSIM, "the PNG capture back", r'"--type=bmp", str\(shot\)\]', "str(shot)]", "lacks \"--type=bmp\""),
        (RUNSIM, "the answer not naming its ask",
         r'\("ok" if rc == 0 else "err"\) \+ \(f" \{rid\}" if rid else ""\)', '("ok" if rc == 0 else "err")',
         "lacks (\"ok\" if rc == 0"),
        (SWIFT, "a late answer taken as this ask's",
         r"\n\s+guard head\.count == 2, head\[1\] == id else \{ continue \}",
         "", "lacks guard head.count"),
        (SWIFT, "the timeout without the watcher's account",
         r"let doing = \(fm\.contents\(atPath: doingPath\)",
         "let doing = (Optional<Data>.none", "lacks let doing"),
    ]
    for rel, label, pattern, repl, want in cuts:
        broken = g.doctor(f"simscreen: {label}", sources[rel], pattern, lambda m, repl=repl: repl)
        got = findings({**sources, rel: broken})
        print(f"{g.name}: simscreen negative ({label}): {len(got)} finding(s)")
        g.negative(f"simscreen: {label}", lambda got=got: got, want=want)

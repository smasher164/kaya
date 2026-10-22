"""A linux drag that never began says who got the press (docs/traps.md, the
witness window over kaya's at the press).

`no drag began within 5000ms` was all a red bundle carried, and the cause
was another client's window under the press. No scene can see this record
go: it prints only on a drag that did not begin, so the driver's pointer
readings and the verb's source side are held here."""

import ast
import re

from kaya_gate import ROOT

DRAGDRIVE = "tools/linux/dragdrive.py"
GTK = "crates/kaya/src/gtk.rs"
WITNESS_LEG = "tools/linux/dragwitness-leg.py"


def py_fn(text, name):
    lines = text.splitlines(keepends=True)
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return "".join(lines[node.lineno - 1:node.end_lineno])
    return ""


def rust_fn(text, header):
    at = text.find(header)
    start = text.find("{", at) if at >= 0 else -1
    if start < 0:
        return ""
    depth = 0
    for i in range(start, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[start:i + 1]
    return ""


def findings(src):
    out = []
    d, g = src[DRAGDRIVE], src[GTK]
    leg = py_fn(src[WITNESS_LEG], "run")
    park, launch = leg.find("park_witness(proto, witness"), leg.find("kaya = subprocess.Popen(")
    if park < 0 or launch < 0 or park > launch:
        out.append(f"drag begin: {WITNESS_LEG}'s run() starts kaya before it parks the "
                   f"witness, so the witness can sit over kaya's window at the instrument press")
    legsrc = src[WITNESS_LEG]
    if '"--onlyvisible", "--pid"' not in py_fn(legsrc, "x11_window_of"):
        out.append(f"drag begin: {WITNESS_LEG}'s x11_window_of takes an unmapped window, "
                   f"so a 1x1 window of kaya's places the witness over kaya (docs/traps.md, the "
                   f"witness placed beside kaya's unmapped window)")
    legdrive = py_fn(legsrc, "drive")
    placed = legdrive.find("place(proto, witness.pid, clear_of(kaya_box, box))")
    refused = legdrive.find("raise DragDriveError(overlap)")
    gesture = legdrive.find("injector_argv(proto, default_injector(proto), start, end)")
    if placed < 0 or refused < placed or gesture < refused:
        out.append(f"drag begin: {WITNESS_LEG}'s drive() no longer refuses a witness still "
                   f"over kaya's window between placing it and the gesture")
    if ("the leg's own release point" not in legdrive or "the leg's own press" not in legdrive
            or "out(x11_reading(owner.pid, when))" not in legdrive):
        out.append(f"drag begin: {WITNESS_LEG}'s drive() no longer says whose window is under "
                   f"its own press and release points")
    drive = py_fn(d, "drive")
    if 'readings.append(x11_reading(pid, "before the press"))' not in drive:
        out.append(f"drag begin: {DRAGDRIVE}'s drive() no longer reads the window under "
                   f"the pointer before the x11 press")
    if "gate = out.stdout.strip().splitlines() + readings" not in drive:
        out.append(f"drag begin: {DRAGDRIVE}'s drive() leaves its pointer readings off "
                   f"the line it prints")
    if "lib.XQueryPointer(" not in py_fn(d, "x11_pointer"):
        out.append(f"drag begin: {DRAGDRIVE}'s x11_pointer no longer asks XQueryPointer")
    if "NOT this guest's" not in py_fn(d, "x11_window_words"):
        out.append(f"drag begin: {DRAGDRIVE}'s x11_window_words no longer says when the "
                   f"window is another client's")
    verb = rust_fn(g, "    fn drag(\n")
    if not verb:
        return out + ["drag begin: gtk.rs has no `fn drag(` verb to read — re-point this clause"]
    for needle, n, why in (
            ("Self::on_main(watch_source_side);", 1, "never watches its windows"),
            ("*SOURCE_SIDE.lock().unwrap() = Some(SourceSide::default());", 1,
             "never arms the source side"),
            ('crate::vtrace::note("drag", format_args!("{words}"));', 2,
             "records no source side in the verb trace on both protocols")):
        if verb.count(needle) < n:
            out.append(f"drag begin: gtk.rs's drag verb {why}")
    if "how long it held; {words}" not in verb or "releasing anyway; {words}" not in verb:
        out.append("drag begin: a no-drag-began sentence in gtk.rs's drag verb no longer "
                   "carries the source side")
    if "gtk4::PropagationPhase::Capture" not in rust_fn(g, "fn watch_source_side("):
        out.append("drag begin: gtk.rs's watch_source_side no longer reads the capture phase")
    for header in ("fn install_drag_source(", "fn install_reorder("):
        body = rust_fn(g, header)
        if "watch_drag_source(&source);" not in body or "s.prepare += 1" not in body:
            out.append(f"drag begin: gtk.rs's {header[3:-1]} no longer counts its "
                       f"source's gesture and prepare")
    if "FROM A DRAG THIS PROCESS NEVER" not in rust_fn(g, "fn report_drop_side("):
        out.append("drag begin: gtk.rs's report_drop_side no longer names a drop from a "
                   "drag this process never began")
    return out


CUTS = [
    ("the witness parked after kaya starts", WITNESS_LEG,
     r"^    try:\n        park_witness\(proto, witness, witness_said\)\n",
     "    try:\n        pass\n", "starts kaya before it parks the witness"),
    ("the witness placed beside an unmapped window", WITNESS_LEG,
     r'"--onlyvisible", "--pid"', '"--pid"', "takes an unmapped window"),
    ("the overlapping witness not refused", WITNESS_LEG,
     r"^    if overlap:\n        raise DragDriveError\(overlap\)\n", "",
     "no longer refuses a witness still over kaya's window"),
    ("the leg's own points unread", WITNESS_LEG,
     r"out\(x11_reading\(owner\.pid, when\)\)", "pass",
     "whose window is under its own press and release points"),
    ("the press's window unread", DRAGDRIVE,
     r'^ +readings\.append\(x11_reading\(pid, "before the press"\)\)\n', "",
     "before the x11 press"),
    ("the readings left off the printed line", DRAGDRIVE,
     r"splitlines\(\) \+ readings", "splitlines()", "off the line it prints"),
    ("another client's window not named", DRAGDRIVE,
     r"NOT this guest's \(pid", "someone's (pid", "another client's"),
    ("the source side never armed", GTK,
     r"^ +\*SOURCE_SIDE\.lock\(\)\.unwrap\(\) = Some\(SourceSide::default\(\)\);\n", "",
     "never arms the source side"),
    ("the x11 sentence without the source side", GTK,
     r"releasing anyway; \{words\}", "releasing anyway", "no longer carries the source side"),
    ("the declared source's gesture uncounted", GTK,
     r'^ +#\[cfg\(feature = "harness"\)\]\n +watch_drag_source\(&source\);\n(?= +// GDK reports)',
     "", "install_drag_source no longer counts"),
    ("the foreign drop unnamed", GTK,
     r"FROM A DRAG THIS PROCESS NEVER", "FROM A DRAG", "never began"),
]


def run(g):
    src = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in (DRAGDRIVE, GTK, WITNESS_LEG)}
    g.counted("drag-begin record clauses held", list(range(15)), floor=15)
    for line in findings(src):
        g.finding(line)
    for label, rel, pattern, repl, want in CUTS:
        broken = dict(src)
        broken[rel] = g.doctor(f"drag begin: {label}", src[rel], pattern, repl, flags=re.M)
        g.negative(f"drag begin: {label}", lambda broken=broken: findings(broken), want=want)

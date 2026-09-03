#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# Compile-check the Java binding and every guest against the real
# desktop KayaRing (bindings/java-desktop). Globbed, not listed: a
# hand-maintained file list here once skipped three scenes silently.

import atexit
import hashlib
import re
import subprocess

# Line-buffered stdout: javac and the exercisers write to the same fd,
# and block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

g = Gate("java-typecheck")


def fail(msg):
    print(f"java-typecheck: {msg}")
    raise SystemExit(1)


def _tool(name):
    # `javac -version` rather than `command -v`: macOS ships a stub
    # javac that exists on PATH but errors without a JDK installed.
    probe = subprocess.run([name, "-version"],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
    if probe.returncode == 0:
        return [name]
    return ["nix", "shell", "nixpkgs#jdk17", "-c", name]


JAVAC = _tool("javac")
JAVA = _tool("java")


def run_javac(*args, log=None):
    out = subprocess.PIPE if log is not None else None
    r = subprocess.run([*JAVAC, *[str(a) for a in args]], cwd=ROOT,
                       stdout=out, stderr=subprocess.STDOUT if log
                       is not None else None, check=False)
    if log is not None:
        log.write_bytes(r.stdout)
    return r.returncode


def run_java(*args, log=None):
    out = subprocess.PIPE if log is not None else None
    r = subprocess.run([*JAVA, *[str(a) for a in args]], cwd=ROOT,
                       stdout=out, stderr=subprocess.STDOUT if log
                       is not None else None, check=False)
    if log is not None:
        log.write_bytes(r.stdout)
    return r.returncode


TMP = g.scratch()
# javac drops a `javac.<stamp>.args` in the CURRENT DIRECTORY on some
# diagnostic paths — measured 2026-08-24 against "method forEach in
# class RowSurface cannot be applied to given types", no crash
# involved. The sources are relative, so the compiler runs at the repo
# root and the debris lands in the working tree; the gate that invoked
# it takes it away, on every exit path.
atexit.register(lambda: [p.unlink() for p in ROOT.glob("javac.*.args")])

# THE NESTED-TABLE EXERCISER, this language's answer to Rust's doc-tests
# (docs/tables-plan.md, dynamic tables): no Java guest declares a table
# inside a row template, so without this the spelling ships compiled by
# nothing. Both zones are here. NO SMUGGLE ANYWHERE IN IT: the nested For
# is a VALUE the loop is written over, so the node its header bar and
# sort handler name is an ordinary local.
(TMP / "probe").mkdir()
(TMP / "probe" / "NestedTableCheck.java").write_text('''\
// IN THE GUESTS' PACKAGE so the generated record surface is in reach:
// the emitted <Rec>Kaya classes are package-private, and the nested
// overload is what this file exists to compile.
package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;

/** A table per row: the header bar declared on a nested For, one sort
 * handler for every stamped copy, and a re-declaration that names ONE
 * copy by its keys. Compiled by tools/java-typecheck.py, never run. */
public final class NestedTableCheck {
    private static final String[] TITLES = { "Symbol", "Value" };

    /** The nested For, through the row surface a scalar rows() yields. */
    static void nestedTable(KayaApp app) {
        app.build(tx -> {
            KayaApp.Collection accounts = tx.collection();
            KayaApp.Rows<KayaApp.Widget, KayaApp.Row> outer = tx.rows(accounts);
            for (KayaApp.Row account : outer) {
                account.label(account.value());
                // The nested collection is declared INSIDE the template
                // scope (the own-scope wall).
                KayaApp.Collection positions = account.collection();
                KayaApp.Rows<KayaApp.Node, KayaApp.Row> inner = account.rows(positions);
                for (KayaApp.Row position : inner) {
                    position.row(() -> {
                        position.label(position.value());
                        position.label(position.value());
                    });
                }
                account.setGrow(inner.handle, 1);
                inner.columns(TITLES, KayaApp.Sort.none());
                // The handler scopes to the For that made it, and the
                // copy's key path comes back with the column, so the
                // re-declaration moves THIS copy's arrow and no
                // sibling's.
                app.onSort(inner.handle, (t, keys, column) -> {
                    t.columnsAt(inner.handle, keys, TITLES, KayaApp.Sort.asc(column));
                });
            }
            tx.mount(outer.handle);
            return null;
        });
    }

    /** The same nesting through a GENERATED record surface: the rows
     * value takes the row it is nested in, and hands back that zone's
     * template node.
     *
     * <p>THE COLLECTION IS DECLARED FROM THE ROW, not from the enclosing
     * Tx: a nested collection may only be declared in the template
     * scope, and the zone handle is what says so at the surface rather
     * than by where the call happens to sit (the ledger's
     * nested-record-collection entry). And `at` keeps the element type, so
     * ONE stamped copy's table is filled with records — a
     * KayaApp.Collection there would take a bare Object and the row's
     * named fields would be unreachable. */
    static void nestedRecordTable(KayaApp app) {
        app.build(tx -> {
            KayaApp.Collection accounts = tx.collection();
            for (KayaApp.Row account : tx.rows(accounts)) {
                KayaRecords.Collection<String, Table.TableItem> positions =
                        KayaRecords.collectionOf(account, Table.TableItem.class);
                KayaApp.Rows<KayaApp.Node, TableItemKaya.Row> inner =
                        TableItemKaya.rows(account, positions);
                for (TableItemKaya.Row position : inner) {
                    position.row(() -> {
                        position.label(position.name);
                        position.label(position.size);
                    });
                }
                inner.columns(TITLES, KayaApp.Sort.none());
                app.onSort(inner.handle, (t, keys, column) -> {
                    KayaRecords.Collection<String, Table.TableItem> copy =
                            positions.at(keys.get(0));
                    copy.insert(t, "aapl", new Table.TableItem("AAPL", "10"));
                    copy.updateField(t, "aapl", TableItemKaya.SIZE, "20");
                    t.columnsAt(inner.handle, keys, TITLES, KayaApp.Sort.desc(column));
                });
            }
            return null;
        });
    }

    private NestedTableCheck() {}
}
''', encoding="utf-8")

# -Xlint:unchecked -Werror ON THE MAIN COMPILE ONLY: an unchecked warning
# is a compile failure here, so raw-generics slips die at the gate instead
# of scrolling past as javac notes. A legitimate erasure idiom carries its
# own @SuppressWarnings at the site.
main_sources = (
    ["bindings/java-desktop/dev/kaya/KayaRing.java"]
    + sorted(str(p.relative_to(ROOT))
             for p in (ROOT / "bindings" / "java" / "dev"
                       / "kaya").glob("*.java"))
    + sorted(str(p.relative_to(ROOT))
             for p in (ROOT / "guests" / "java" / "dev" / "kaya"
                       / "guests").glob("*.java"))
    + [str(TMP / "probe" / "NestedTableCheck.java")]
)
if run_javac("-encoding", "UTF-8", "-Xlint:unchecked", "-Werror", "-d",
             TMP / "classes", *main_sources) != 0:
    fail("FAIL")

# ITS NEGATIVE, the compile_fail doc-test's shape: a nested sort
# handler that drops the copy's key path must not compile. Without this
# the exerciser above only proves the surface EXISTS — not that the key
# path is part of the message.
(TMP / "probe" / "NestedTableDropsPath.java").write_text('''\
import dev.kaya.KayaApp;

public final class NestedTableDropsPath {
    static void cannotDropThePath(KayaApp app, KayaApp.Node table) {
        app.onSort(table, (tx, column) -> { });
    }

    private NestedTableDropsPath() {}
}
''', encoding="utf-8")

if run_javac("-encoding", "UTF-8", "-cp", TMP / "classes", "-d",
             TMP / "rejected", TMP / "probe" / "NestedTableDropsPath.java",
             log=TMP / "rejected.log") == 0:
    fail("FAIL — a nested onSort that DROPS the stamped copy's key path "
         "compiled. The handler must take (Tx, List<Object> keys, int "
         "column): without the keys a re-declaration cannot name the "
         "copy that was clicked (the tables plan's per-copy identity "
         "rule).")

# ITS SIBLING: a rows value carries the handle of the zone it opened
# in, and the TYPE is the wall. A nested For's container is a template
# Node — read as a live Widget it would reach the live onSort, whose
# handler takes no key path, and every stamped copy's header would
# answer as one.
(TMP / "probe" / "RowsWrongZone.java").write_text('''\
import dev.kaya.KayaApp;

public final class RowsWrongZone {
    static void cannotReadANestedForAsLive(KayaApp.Row account, KayaApp.Collection c) {
        KayaApp.Widget live = account.rows(c).handle;
    }

    private RowsWrongZone() {}
}
''', encoding="utf-8")

if run_javac("-encoding", "UTF-8", "-cp", TMP / "classes", "-d",
             TMP / "rejected", TMP / "probe" / "RowsWrongZone.java",
             log=TMP / "rejectedzone.log") == 0:
    fail("FAIL — a NESTED rows value's handle read as a live Widget "
         "compiled. A For inside a row template declares a template "
         "node, one stamped container per copy; typing it live would "
         "reach the live onSort, whose handler has no key path to name "
         "a copy with (the tables plan's per-copy identity rule).")

# A RECORD HAS NO SIZE CEILING, and this one is RUN rather than compiled
# — the only clause in this file that is. A fixed ByteBuffer.allocate(4096)
# capped every java record at 4064 characters of text or 252 wire values
# (docs/deferred.md, java-record-ceiling), and nothing else in the tree can
# see it: no scene sets a 4KB label, and the ceiling is a THROW.
(TMP / "big").mkdir()
(TMP / "big" / "LargeRecordCheck.java").write_text('''\
import dev.kaya.KayaWire;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Encode past the old ceiling and read it back. The sizes are the
 * MEASURED ones: 4064 characters was the largest text prop the fixed
 * 4096-byte buffer could hold, so 4065 is the first that threw. */
public final class LargeRecordCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("large-record: FAIL — " + what);
            System.exit(1);
        }
    }

    private static String text(int chars) {
        StringBuilder sb = new StringBuilder(chars);
        for (int i = 0; i < chars; i++) sb.append((char) ('a' + (i % 26)));
        return sb.toString();
    }

    /** The framing every record shares: a u32 size that IS the length,
     * the kind, and a body padded to 8. */
    private static ByteBuffer framed(byte[] rec, short kind, String what) {
        ByteBuffer b = ByteBuffer.wrap(rec).order(ByteOrder.LITTLE_ENDIAN);
        check(b.getInt(0) == rec.length,
                what + ": size field " + b.getInt(0) + " but " + rec.length + " bytes");
        check(b.getShort(4) == kind, what + ": wrong record kind");
        check(rec.length % 8 == 0, what + ": body not padded to 8");
        return b;
    }

    /** txSetText is {header, u64 widget, u32 prop, u32 source, value}. */
    private static void roundTripText(int chars) {
        String want = text(chars);
        byte[] rec = KayaWire.txSetText(7L, want);
        ByteBuffer b = framed(rec, KayaWire.TX_KIND_SET_PROPERTY, chars + "-char text");
        check(b.getLong(8) == 7L, chars + "-char text: widget id");
        int[] cursor = { 24 };
        Object back = KayaWire.parseValue(rec, b, cursor);
        check(want.equals(back), chars + "-char text: did not round-trip");
        check(cursor[0] == rec.length, chars + "-char text: value did not fill the record");
    }

    public static void main(String[] args) {
        roundTripText(2);
        roundTripText(4064);
        roundTripText(4065);
        roundTripText(100000);

        // {header, u64 widget, value vb_w, value vb_h, u32 count,
        //  u32 path_len, {u32 n, u32 reserved, n values}} — ops from 64.
        int n = 20000;
        Object[] ops = new Object[n];
        for (int i = 0; i < n; i++) ops[i] = (long) i;
        byte[] rec = KayaWire.txSetDrawing(9L, 100.0, 50.0, n, 0, ops);
        ByteBuffer b = framed(rec, KayaWire.TX_KIND_SET_DRAWING, n + "-value drawing");
        check(b.getLong(8) == 9L, "drawing: widget id");
        check(b.getInt(48) == n, "drawing: op count");
        check(b.getInt(52) == 0, "drawing: path_len");
        check(b.getInt(56) == n, "drawing: value count");
        int[] cursor = { 64 };
        for (int i = 0; i < n; i++) {
            Object v = KayaWire.parseValue(rec, b, cursor);
            check(v instanceof Long && (Long) v == i, "drawing: op " + i + " did not round-trip");
        }
        check(cursor[0] == rec.length, "drawing: ops did not fill the record");

        System.out.println("large-record: OK — a " + rec.length + "-byte drawing and a"
                + " 100000-character text prop encoded and round-tripped");
    }

    private LargeRecordCheck() {}
}
''', encoding="utf-8")

if run_javac("-encoding", "UTF-8", "-cp", TMP / "classes", "-d",
             TMP / "bigclasses",
             TMP / "big" / "LargeRecordCheck.java") != 0:
    fail("FAIL — the large-record exerciser did not compile.")

if run_java("-cp", f"{TMP / 'classes'}:{TMP / 'bigclasses'}",
            "LargeRecordCheck") != 0:
    fail("FAIL — a record past 4096 bytes did not encode and "
         "round-trip. KayaWire's encode buffer must GROW (the Enc "
         "wrapper in tools/kaya-bindgen/src/java.rs); a fixed "
         "ByteBuffer caps every record, which is a text prop of 4064 "
         "characters and a drawing of 252 values.")

# ITS WATCHED NEGATIVE: the growth removed from a COPY, the substitution
# COUNTED, and the same exerciser required to throw for the RIGHT reason.
(TMP / "fixedwire").mkdir()
for p in sorted((ROOT / "bindings" / "java" / "dev" / "kaya")
                .glob("*.java")):
    (TMP / "fixedwire" / p.name).write_bytes(p.read_bytes())
wire_before = hashlib.sha256(
    (ROOT / "bindings" / "java" / "dev" / "kaya"
     / "KayaWire.java").read_bytes()).hexdigest()

# The whole body of Enc.at, replaced by a buffer that never grows —
# which is the pre-fix fixed ByteBuffer.allocate(4096) exactly. The
# closing brace is anchored at EIGHT spaces: the `if (need < 0)` block
# inside the body closes at twelve, and a lazier pattern would doctor
# that instead and still print 1.
fixed = TMP / "fixedwire" / "KayaWire.java"
fixed.write_text(
    g.doctor("ceiling negative doctored Enc.at's body",
             fixed.read_text(encoding="utf-8"),
             r"( *private ByteBuffer at\(int extra\) \{\n).*?"
             r"(\n        \}\n)",
             r"\1            return b;\2", flags=re.S),
    encoding="utf-8")

if run_javac("-encoding", "UTF-8", "-d", TMP / "fixedclasses",
             "bindings/java-desktop/dev/kaya/KayaRing.java",
             *sorted((TMP / "fixedwire").glob("*.java"))) != 0:
    fail("FAIL — the doctored copy did not compile, so the ceiling "
         "negative proved nothing. Enc.at's body must be replaceable "
         "by `return b;` on its own.")

if run_java("-cp", f"{TMP / 'fixedclasses'}:{TMP / 'bigclasses'}",
            "LargeRecordCheck", log=TMP / "ceiling.log") == 0:
    fail("FAIL — the large-record exerciser PASSED against an encode "
         "buffer that cannot grow. It is therefore not exercising the "
         "ceiling, and the clause above is green for some other "
         "reason.")
ceiling_log = (TMP / "ceiling.log").read_text(encoding="utf-8",
                                              errors="replace")
if "BufferOverflowException" not in ceiling_log:
    print("java-typecheck: FAIL — the doctored encoder failed, but NOT "
          "with BufferOverflowException, so the negative did not watch "
          "the ceiling. What it printed:")
    print(ceiling_log)
    raise SystemExit(1)

# The tree is untouched by the perturbation above — asserted, not
# assumed.
wire_after = hashlib.sha256(
    (ROOT / "bindings" / "java" / "dev" / "kaya"
     / "KayaWire.java").read_bytes()).hexdigest()
if wire_after != wire_before:
    fail("FAIL — bindings/java/dev/kaya/KayaWire.java changed during "
         "the ceiling negative. It must only ever doctor the copy in "
         "the scratch directory.")

# ONE APP PER PROCESS, AND THE REFUSAL MADE TO PRINT (docs/deferred.md's
# mount entry): kaya's core is a process-global singleton, so two Apps
# mint ids from two counters into one scene and the core dies on the first
# collision, three removes from the mistake. NOTHING ELSE REACHES IT — no
# guest builds two, and on Android kaya starts the app thread itself.
(TMP / "once").mkdir()
(TMP / "once" / "BuildOnceCheck.java").write_text('''\
import dev.kaya.KayaApp;

/** A second App in one process is refused, and the sentence says why.
 * Compiled and RUN by tools/java-typecheck.py. */
public final class BuildOnceCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("build-once: FAIL — " + what);
            System.exit(1);
        }
    }

    public static void main(String[] args) {
        new KayaApp();
        try {
            new KayaApp();
            check(false, "a second App in one process was accepted");
        } catch (IllegalStateException e) {
            check(e.getMessage() != null
                            && e.getMessage().contains("a second App in this process"),
                    "the refusal did not name a second App: " + e.getMessage());
        }
        System.out.println("build-once: OK — a second App is refused, by its own sentence");
    }

    private BuildOnceCheck() {}
}
''', encoding="utf-8")

if run_javac("-encoding", "UTF-8", "-cp", TMP / "classes", "-d",
             TMP / "onceclasses",
             TMP / "once" / "BuildOnceCheck.java") != 0:
    fail("FAIL — the build-once exerciser did not compile.")

if run_java("-cp", f"{TMP / 'classes'}:{TMP / 'onceclasses'}",
            "BuildOnceCheck") != 0:
    fail("FAIL — a second KayaApp in one process was not refused, or "
         "was refused by a sentence that does not name the cause. "
         "kaya's core is a process-global singleton (docs/deferred.md's "
         "mount entry); two Apps mint ids from two counters and the "
         "core dies on the first collision.")

# ITS WATCHED NEGATIVE, the ceiling clause's shape: the latch removed
# from a COPY, the substitution COUNTED, and the same exerciser required
# to report that a second App got through.
(TMP / "unlatched").mkdir()
for p in sorted((ROOT / "bindings" / "java" / "dev" / "kaya")
                .glob("*.java")):
    (TMP / "unlatched" / p.name).write_bytes(p.read_bytes())
app_before = hashlib.sha256(
    (ROOT / "bindings" / "java" / "dev" / "kaya"
     / "KayaApp.java").read_bytes()).hexdigest()

unlatched = TMP / "unlatched" / "KayaApp.java"
unlatched.write_text(
    g.doctor("build-once negative unlatched the constructor",
             unlatched.read_text(encoding="utf-8"),
             r"if \(BUILT\.getAndSet\(true\)\) \{", "if (false) {"),
    encoding="utf-8")

if run_javac("-encoding", "UTF-8", "-d", TMP / "unlatchedclasses",
             "bindings/java-desktop/dev/kaya/KayaRing.java",
             *sorted((TMP / "unlatched").glob("*.java"))) != 0:
    fail("FAIL — the unlatched KayaApp copy did not compile.")

if run_java("-cp", f"{TMP / 'unlatchedclasses'}:{TMP / 'onceclasses'}",
            "BuildOnceCheck", log=TMP / "unlatched.log") == 0:
    fail("FAIL — the build-once exerciser PASSED against a KayaApp "
         "whose latch was removed. It is therefore not exercising the "
         "latch, and the clause above is green for some other reason.")
unlatched_log = (TMP / "unlatched.log").read_text(encoding="utf-8",
                                                  errors="replace")
if "a second App in one process was accepted" not in unlatched_log:
    print("java-typecheck: FAIL — the unlatched copy failed, but NOT "
          "by accepting a second App, so the negative did not watch "
          "the latch. What it printed:")
    print(unlatched_log)
    raise SystemExit(1)

app_after = hashlib.sha256(
    (ROOT / "bindings" / "java" / "dev" / "kaya"
     / "KayaApp.java").read_bytes()).hexdigest()
if app_after != app_before:
    fail("FAIL — bindings/java/dev/kaya/KayaApp.java changed during "
         "the build-once negative. It must only ever doctor the copy "
         "in the scratch directory.")

g.verdict()

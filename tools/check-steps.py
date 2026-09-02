#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# Lint the shared .steps scripts: container-kind targets index widgets
# by CREATION order, which legitimately differs per language
# (statement-shaped construction is parent-first, expression trees are
# children-first — argument evaluation forces it). Leaf kinds are safe
# (body order is screen order everywhere); containers are targetable
# only through the blessed pattern — column#0, the For container that
# the root-is-a-row convention keeps unique. Anything else would name
# different widgets on different platforms, so it dies here, not in
# one platform's leg.

import hashlib
import platform
import re
import shutil
import subprocess
import tempfile

# The windows lane's tables — roster, order, drain structure — are DATA
# since the runner conversion (docs/runner-conversion-plan.md §2); the
# clauses that used to regex tools/deploy-win.sh's text import what the
# runner imports.
from lanes import android as android_lane
from lanes import ios as ios_lane
from lanes import mac as mac_lane
from lanes import win as win_lane

# Line-buffered stdout: the probes and helper scripts write to the same
# fd, and block-buffered prints would land AFTER output they preceded.
sys.stdout.reconfigure(line_buffering=True)

status = 0


def sub_count(pattern, repl, text, flags=0):
    """re.sub with the number of applications. Rule 6 routes re.subn
    through the prelude's doctor; these perturbations print their
    counts in each clause's own historical words, so they count through
    re.sub instead — same substitutions, same numbers."""
    n = 0

    def _apply(m):
        nonlocal n
        n += 1
        return m.expand(repl)

    return re.sub(pattern, _apply, text, flags=flags), n


def sub_first(pattern, repl, text, flags=0):
    """The first match alone — what re.subn(count=1) did."""
    m = re.compile(pattern, flags).search(text)
    if not m:
        return text, 0
    return text[:m.start()] + m.expand(repl) + text[m.end():], 1


def read_rel(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


STEPS = sorted((ROOT / "tools" / "scenes").glob("*.steps"))
STEPS_TEXT = {p: p.read_text(encoding="utf-8") for p in STEPS}


def steps_rel(p):
    return str(p.relative_to(ROOT))


# --- the container-target lint ----------------------------------------
TARGET_KINDS = (
    "button", "checkbox", "slider", "entry", "label", "column", "row",
    "image", "scroll", "progress", "select", "radio", "grid",
    "textarea", "canvas",
)
TARGET_RE = re.compile(r"\b(" + "|".join(TARGET_KINDS) + r")@([^\s;]*)")
INDEX_RE = re.compile(r"\b(" + "|".join(TARGET_KINDS) + r")#([^\s;]*)")


def _unquoted(line):
    quoted = False
    escaped = False
    out = []
    for c in line:
        if quoted:
            out.append(" ")
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == chr(34):
                quoted = False
        elif c == chr(34):
            quoted = True
            out.append(" ")
        else:
            out.append(c)
    return "".join(out)


def _authored_target(token):
    kind, authored = token.split("@", 1)
    open_at = authored.find("[")
    if open_at >= 0:
        if not authored.endswith("]"):
            return None
        id_ = authored[:open_at]
        key_text = authored[open_at + 1:-1]
        if any(c in id_ for c in "[]@") or "[" in key_text \
                or "]" in key_text:
            return None
        keys = key_text.split(".")
        if not key_text or any(not key for key in keys):
            return None
    else:
        if "]" in authored or "@" in authored:
            return None
        id_, keys = authored, None
    if not id_:
        return None
    return kind, id_, keys


def lint(text, path):
    """Offender lines for one steps script."""
    bad = []
    zero_at = {}
    kinds_seen = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        code = _unquoted(line)
        for match in TARGET_RE.finditer(code):
            token = match.group(0)
            parsed = _authored_target(token)
            if parsed is None:
                bad.append(
                    f"{path}:{lineno}: malformed target {token!r}; "
                    "wanted kind@id or kind@id[key.path] with non-empty "
                    "dot-joined string keys")
                continue
            kind, id_, keys = parsed
            if kind in ("row", "column", "scroll", "grid"):
                suffix = ("" if keys is None
                          else "[" + ".".join(keys) + "]")
                kinds_seen.setdefault(kind, set()).add(
                    "@" + id_ + suffix)
        for match in INDEX_RE.finditer(code):
            kind, index = match.groups()
            token = match.group(0)
            if index != "last" \
                    and re.fullmatch(r"[0-9]+", index) is None:
                bad.append(
                    f"{path}:{lineno}: malformed target {token!r}; "
                    "wanted kind#index with one numeric or last suffix")
                continue
            if kind not in ("row", "column", "scroll", "grid"):
                continue
            # Index 0 of a container kind is the blessed pattern, on
            # one convention: the scene ADDRESSES exactly one widget of
            # that kind, so creation order cannot enter. column#0 is
            # the For container in milestone2 (root-is-a-row keeps it
            # unique); row#0 carries the horizontal grow contract in
            # the grow scene; scroll#0 the one scroll viewport in the
            # scroll scene. The convention is CHECKED, not assumed,
            # below: a scene that also addresses a SECOND container of
            # the kind has lost the uniqueness that made #0 stable —
            # Haskell builds children first, so an outer container of a
            # kind indexes AFTER the inner ones (measured 2026-08-22:
            # the align scene put three columns on screen and column#0
            # was the root everywhere but Haskell, where it was the
            # innermost).
            if index == "0":
                zero_at.setdefault(kind, []).append(lineno)
                kinds_seen.setdefault(kind, set()).add("#0")
                continue
            kinds_seen.setdefault(kind, set()).add("#" + index)
            if index != "last":
                bad.append(f"{path}:{lineno}: {kind}#{index}")
    for kind, lines in zero_at.items():
        if len(kinds_seen.get(kind, set())) > 1:
            others = "/".join(sorted(t for t in kinds_seen[kind]
                                     if t != "#0"))
            for lineno in lines:
                bad.append(
                    f"{path}:{lineno}: {kind}#0 beside {kind}{others} "
                    f"— the scene addresses more than one {kind}, so "
                    f"index 0 is no longer creation-order stable; "
                    f"author a key")
    return bad


def selftest_fail(msg):
    print(f"check-steps: SELF-TEST FAIL ({msg})", file=sys.stderr)
    raise SystemExit(1)


# The guard guards itself: a known-bad sample must fail, or the lint is
# a false green.
if not lint('click row#1\nexpect column#2 "x"\n', "-"):
    selftest_fail("bad sample passed")
# The uniqueness clause too: #0 beside an authored key of the same kind
# is the exact shape that broke on Haskell (children-first creation).
if not lint('expect_aligned column#0 "stretch"\n'
            'expect_aligned column@x[brokerage] "center"\n', "-"):
    selftest_fail("column#0 beside column@x[brokerage] passed")
# And the blessed lone #0 still passes, or every legacy scene reddens.
if lint("expect_fills column#0\nexpect_fills row#0\n", "-"):
    selftest_fail("lone column#0/row#0 refused")
# Both authored forms and a deep string path pass.
if lint('expect_columns column@positions "A|B"\n'
        'expect_columns column@positions[brokerage] "A|B"\n'
        'expect_columns column@positions[brokerage.taxable] "A|B"\n',
        "-"):
    selftest_fail("well-formed authored targets were refused")
# Every delimiter failure the three parsers reject must fail here too.
for target in (
    "column@", "column@positions[]", "column@positions[.a]",
    "column@positions[a.]", "column@positions[a..b]",
    "column@positions[a", "column@positions[a]]",
    "column@positions[[a]", "column@positions][a]",
    "column@positions[a][b]",
):
    grammar_out = lint(f'expect_columns {target} "A|B"\n', "-")
    if not grammar_out:
        selftest_fail(f"malformed target {target} passed")
    if not any(f"malformed target '{target}'" in b
               for b in grammar_out):
        selftest_fail(f"{target} failed for another reason): "
                      + "\n".join(grammar_out))
# Indexed targets preserve the sole legacy spelling; empty or repeated
# separators cannot depend on one parser's split defaults.
if lint("click button#0\nclick button#last\n", "-"):
    selftest_fail("well-formed indexed targets were refused")
for target in ("button#", "button##0", "button#0#1", "button#last#"):
    grammar_out = lint(f"click {target}\n", "-")
    if not grammar_out:
        selftest_fail(f"malformed target {target} passed")
    if not any(f"malformed target '{target}'" in b
               for b in grammar_out):
        selftest_fail(f"{target} failed for another reason): "
                      + "\n".join(grammar_out))

for p in STEPS:
    out = lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} targets a container by "
              f"creation index — only column#0/row#0 "
              f"(unique-by-convention containers) are cross-language "
              f"stable:", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1

# The keyed-target grammar has THREE parsers. The desktop scene reaches
# two; this source wall keeps Compose on the same route before Android
# carries that scene (docs/tables-plan.md, dynamic tables).
TARGET_HARNESS = "crates/kaya/src/harness.rs"
TARGET_SWIFT = "swift/KayaSwiftUI.swift"
TARGET_KOTLIN = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"


def target_surfaces(harness_src=None, swift_src=None, kotlin_src=None):
    """Findings over the three keyed-target parsers; each source is
    None (the real file) or the doctored TEXT a self-test built."""
    findings = []

    def fail(text):
        findings.append("check-steps: " + text)

    def src_of(override, rel):
        if override is not None:
            return override
        try:
            return read_rel(rel)
        except OSError as exc:
            fail(f"cannot read {rel}: {exc}")
            return None

    def section(text, start, stop, label):
        if text is None:
            return None
        at = text.find(start)
        if at < 0:
            fail(f"{label} has no {start!r} block; the keyed-target "
                 f"checker is blind")
            return None
        end = text.find(stop, at + len(start))
        if end < 0:
            fail(f"{label}'s {start!r} block has no {stop!r} boundary; "
                 f"the keyed-target checker is blind")
            return None
        return text[at:end]

    def has_all(text, parts):
        return text is not None and all(part in text for part in parts)

    harness = src_of(harness_src, TARGET_HARNESS)
    swift = src_of(swift_src, TARGET_SWIFT)
    kotlin = src_of(kotlin_src, TARGET_KOTLIN)

    hparse = section(harness, "fn parse_target(spec: &str)",
                     "fn parse_target_kind(", TARGET_HARNESS)
    if hparse is not None and not has_all(hparse, [
        "spec.split_once('@')",
        "authored.find('[')",
        "!authored.ends_with(']')",
        "keys.is_empty() || keys.split('.').any(str::is_empty)",
        "id.contains(['[', ']', '@'])",
        "authored.contains([']', '@'])",
        "(authored, None)",
        "keys: keys.map",
    ]):
        fail("crates/kaya/src/harness.rs target grammar is not "
             "kind@id[key.path] with bare @ preserved")

    if harness is not None and not has_all(harness, [
        "fn resolve_id(&self, kind: TargetKind, id: &str, "
        "keys: Option<&str>)",
        "stage.resolve_id(t.kind, id, t.keys)",
        "*t = Target { kind: t.kind, index, id: None, keys: None }",
    ]):
        fail("crates/kaya/src/harness.rs keyed targets do not carry "
             "keys through Stage::resolve_id")

    htag = section(harness, "fn table_tag_identity(",
                   "/// Format child main-axis extents", TARGET_HARNESS)
    if htag is not None and not has_all(htag, [
        "crate::wire::VALUE_STR => "
        "Some(std::str::from_utf8(payload).ok()?)",
        "crate::wire::VALUE_I64 if len == 8 => None",
        "keys.split('.')",
        "*got == Some(want)",
    ]):
        fail("crates/kaya/src/harness.rs table target matching is not "
             "string-key-only")
    if htag is not None and "if count == 0 || count >" not in htag:
        fail("crates/kaya/src/harness.rs table stamps can resolve "
             "without copy keys")

    stable = section(swift, "private func kayaTableStamp(",
                     "/// Resolves the target grammar", TARGET_SWIFT)
    starget = section(swift, "private func kayaTarget(",
                      "/// An optional leading `window#N`", TARGET_SWIFT)
    if starget is not None and not has_all(starget, [
        'text.firstIndex(of: "@")',
        'authored.firstIndex(of: "[")',
        'authored.last == "]"',
        '!id.contains(where: { $0 == "[" || $0 == "]" || $0 == "@" })',
        '!keyText.contains(where: { $0 == "[" || $0 == "]" })',
        'keyText.split(separator: ".", '
        'omittingEmptySubsequences: false)',
        '!path.contains(where: { $0.isEmpty })',
        '!authored.contains(where: { $0 == "]" || $0 == "@" })',
        'guard !id.isEmpty else { return nil }',
        'return registry.first { kayaScene.nodes[$0.id] === $0 && '
        '$0.a11yId == id }',
    ]):
        fail("swift/KayaSwiftUI.swift target grammar is not "
             "kind@id[key.path] with bare @ preserved")
    if starget is not None and not has_all(starget, [
        'guard text.filter({ $0 == "#" }).count == 1 else '
        '{ return nil }',
        'text.split(separator: "#", omittingEmptySubsequences: false)',
    ]):
        fail("swift/KayaSwiftUI.swift target grammar does not reject "
             "repeated or trailing #")

    if stable is not None and "guard count > 0, count <=" not in stable:
        fail("swift/KayaSwiftUI.swift table stamps can resolve without "
             "copy keys")
    if stable is not None and "encoding: .utf8" not in stable:
        fail("swift/KayaSwiftUI.swift table stamp keys are not strict "
             "UTF-8")

    if (stable is not None and starget is not None) and not (
        "type == valueStr" in stable
        and "kayaTableStamp($0.sortTag)?.node" in starget
        and "guard let stamp = kayaTableStamp($0.sortTag) else"
        in starget
        and "stamp.node == node && stamp.keys == keys" in starget
    ):
        fail("swift/KayaSwiftUI.swift keyed targets do not resolve "
             "through the table sortTag")

    if starget is not None and \
            "let live = registry.filter { kayaScene.nodes[$0.id] " \
            "=== $0 }" not in starget:
        fail("swift/KayaSwiftUI.swift keyed targets do not filter "
             "destroyed registry entries")

    sany = section(swift, "private func kayaAnyTarget(",
                   "/// Cut one script LINE", TARGET_SWIFT)
    if sany is not None and \
            'switch String(spec.prefix { $0 != "#" && $0 != "@" })' \
            not in sany:
        fail("swift/KayaSwiftUI.swift target kind extraction does not "
             "stop at the earliest #/@")

    stransition = section(
        swift, "func kayaSelftestAdmissionTransition(",
        "private var kayaSelftestAdmissionState", TARGET_SWIFT)
    sapply = section(
        swift, "private func kayaApply(",
        "private func kayaWindowHasMountedContent(", TARGET_SWIFT)
    smounted = section(
        swift, "private func kayaWindowHasMountedContent(",
        "private func kayaDriveSelftestAdmission(", TARGET_SWIFT)
    sdrive = section(
        swift, "private func kayaDriveSelftestAdmission(",
        "/// The interaction harness's Swift interpreter", TARGET_SWIFT)
    sdiagnosis = section(
        swift,
        '// docs/traps.md, "A scene that never mounts measures an '
        'invisible app".',
        "FileHandle.standardError.write(", TARGET_SWIFT)
    sroot = section(swift, "struct KayaRoot: View {",
                    "// Recording mode tiles", TARGET_SWIFT)
    swift_admission_shape_ok = all(
        part is not None
        for part in (stransition, sapply, smounted, sdrive, sdiagnosis,
                     sroot))
    apply_tail = (
        "if menusTouched {\n"
        "        kayaMenuChanged()\n"
        "    }\n"
        "    kayaDriveSelftestAdmission()\n"
        "}")
    if sapply is not None and (
            sapply.count("kayaDriveSelftestAdmission()") != 1
            or apply_tail not in sapply):
        swift_admission_shape_ok = False
        fail("swift/KayaSwiftUI.swift does not admit the harness at "
             "the completed apply-batch boundary")
    if stransition is not None:
        transition_steps = [
            "if state == .started { return (.started, .none) }",
            "if mounted { return (.started, .start) }",
            "if graceExpired {",
            "return state == .grace ? (.started, .start) : "
            "(state, .none)",
            "if state == .waiting && hasNodes { return (.grace, "
            ".armGrace) }",
            "return (state, .none)",
        ]
        positions = [stransition.find(step)
                     for step in transition_steps]
        if any(at < 0 for at in positions) \
                or positions != sorted(positions) \
                or any(stransition.count(step) != 1
                       for step in transition_steps):
            swift_admission_shape_ok = False
            fail("swift/KayaSwiftUI.swift selftest admission "
                 "transition is not terminal, mounted-first, and "
                 "singly armed")
    if smounted is not None and not has_all(smounted, [
        "window.root != nil",
        "window.entries.contains(where: { $0.root != nil })",
        "window.sections.contains { section in",
        "section.root != nil",
        "section.entries.contains(where: { $0.root != nil })",
    ]):
        swift_admission_shape_ok = False
        fail("swift/KayaSwiftUI.swift mounted-content predicate does "
             "not cover window, section, and navigation roots")
    if sdrive is not None:
        mounted_census = ("let mounted = kayaScene.windows.values"
                          ".contains(where: kayaWindowHasMountedContent)")
        if sdrive.count(mounted_census) != 1:
            swift_admission_shape_ok = False
            fail("swift/KayaSwiftUI.swift selftest admission does not "
                 "inspect every mounted surface")
        drive_steps = [
            "dispatchPrecondition(condition: .onQueue(.main))",
            'ProcessInfo.processInfo.environment["KAYA_SELFTEST"] '
            '!= nil',
            "let (next, effect) = kayaSelftestAdmissionTransition(",
            "mounted: mounted",
            "kayaSelftestAdmissionState = next",
            "switch effect {",
            "case .armGrace:",
            "DispatchQueue.main.asyncAfter(deadline: .now() + "
            "kayaSelftestUnmountedGrace)",
            "kayaDriveSelftestAdmission(graceExpired: true)",
            "case .start:",
            "kayaStartSelftest()",
        ]
        positions = [sdrive.find(step) for step in drive_steps]
        if any(at < 0 for at in positions) \
                or positions != sorted(positions) \
                or any(sdrive.count(step) != 1 for step in drive_steps):
            swift_admission_shape_ok = False
            fail("swift/KayaSwiftUI.swift admission driver is not "
                 "main-thread, state-before-effect, and bounded")
    if sdiagnosis is not None:
        diagnosis_steps = [
            "let unmountedNodeCount = DispatchQueue.main.sync { () -> "
            "Int? in",
            "guard !kayaScene.nodes.isEmpty,",
            "kayaScene.windows",
            "else { return nil }",
            "return kayaScene.nodes.count",
            "if let unmountedNodeCount {",
            '"\\(unmountedNodeCount) widgets exist but NO ROOT IS '
            'MOUNTED on any surface "',
        ]
        positions = [sdiagnosis.find(step) for step in diagnosis_steps]
        if any(at < 0 for at in positions) \
                or positions != sorted(positions) \
                or any(sdiagnosis.count(step) != 1
                       for step in diagnosis_steps) \
                or sdiagnosis.count("kayaScene.nodes") != 2 \
                or sdiagnosis.count("kayaScene.windows") != 1:
            swift_admission_shape_ok = False
            fail("swift/KayaSwiftUI.swift final unmounted diagnosis is "
                 "not snapshotted on the main queue")
    if swift is not None and (
        swift.count("private let kayaSelftestUnmountedGrace: "
                    "TimeInterval = 5.0") != 1
        or "kayaScene.windows.values.allSatisfy({ "
           "!kayaWindowHasMountedContent($0) })" not in swift
    ):
        swift_admission_shape_ok = False
        fail("swift/KayaSwiftUI.swift has no five-second all-surface "
             "fallback to the unmounted-scene diagnostic")
    if sroot is not None and (
            sroot.count("kayaStartCommandPump()") != 1
            or "kayaStartSelftest()" in sroot
            or "kayaDriveSelftestAdmission" in sroot):
        swift_admission_shape_ok = False
        fail("swift/KayaSwiftUI.swift starts the harness from primary "
             "onAppear before a mounted batch")
    if swift is not None and swift_admission_shape_ok:
        def executable_calls(spelling, definition):
            return [
                line for line in swift.splitlines()
                if spelling in line.split("//", 1)[0]
                and definition not in line.split("//", 1)[0]
            ]

        call_census = [
            ("kayaStartSelftest()", "func kayaStartSelftest()", 1),
            ("kayaStartCommandPump()", "func kayaStartCommandPump()",
             1),
            ("kayaDriveSelftestAdmission()",
             "func kayaDriveSelftestAdmission(", 1),
            ("kayaDriveSelftestAdmission(graceExpired: true)",
             "func kayaDriveSelftestAdmission(", 1),
        ]
        for spelling, definition, want in call_census:
            got = len(executable_calls(spelling, definition))
            if got != want:
                fail(f"swift/KayaSwiftUI.swift has {got} executable "
                     f"{spelling} call(s), wanted {want}")

    ktable = section(kotlin, "private fun tableStamp(",
                     "private fun target(", TARGET_KOTLIN)
    ktarget = section(kotlin, "private fun target(",
                      "private fun quotedHead(", TARGET_KOTLIN)
    if ktarget is not None and not has_all(ktarget, [
        "spec.indexOf('@')",
        "authored.indexOf('[')",
        "!authored.endsWith(']')",
        "keyText.contains('[') || keyText.contains(']')",
        "id.any { it == '[' || it == ']' || it == '@' }",
        "keys = keyText.split('.')",
        "keyText.isEmpty() || keys.any { it.isEmpty() }",
        "authored.any { it == ']' || it == '@' }",
        "if (id.isEmpty()) return null",
        "KayaSceneModel.nodes[it.id] === it && it.a11yId == id",
    ]):
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
             "target grammar is not kind@id[key.path] with bare @ "
             "preserved")
    if ktarget is not None and not has_all(ktarget, [
        "val hash = spec.indexOf('#')",
        "hash != spec.lastIndexOf('#')",
        "val index = spec.substring(hash + 1)",
        "index.toIntOrNull()",
    ]):
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
             "target grammar does not reject repeated or trailing #")

    if ktable is not None and "if (count == 0L || count >" not in ktable:
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
             "table stamps can resolve without copy keys")
    if ktable is not None and not has_all(ktable, [
        "Charsets.UTF_8.newDecoder()",
        ".onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)",
        ".onUnmappableCharacter(java.nio.charset.CodingErrorAction"
        ".REPORT)",
        ".decode(ByteBuffer.wrap(bytes))",
        "catch (_: java.nio.charset.CharacterCodingException)",
    ]):
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
             "table stamp keys are not strict UTF-8")

    if (ktable is not None and ktarget is not None) and not (
        "type != VALUE_STR" in ktable
        and "tableStamp(it.sortTag)?.node" in ktarget
        and "tableStamp(it.sortTag)?.let { stamp ->" in ktarget
        and "stamp.node == node && stamp.keys == keys" in ktarget
    ):
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
             "keyed targets do not resolve through the table sortTag")

    if ktarget is not None and \
            "val live = registry.filter { KayaSceneModel.nodes[it.id] "\
            "=== it }" not in ktarget:
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
             "keyed targets do not filter destroyed registry entries")

    kwidget = section(kotlin, "private fun kayaWidgetTarget(",
                      "private fun kayaAxRole(", TARGET_KOTLIN)
    if kwidget is not None and \
            "spec.indexOfAny(charArrayOf('#', '@'))" not in kwidget:
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
             "target kind extraction does not stop at the earliest #/@")

    kmount = section(kotlin, "fun mount(activity: ComponentActivity)",
                     "/** The visible title", TARGET_KOTLIN)
    kadmit = section(kotlin, "private fun admitSelftestOnFirstDraw(",
                     "private fun startSelftest(", TARGET_KOTLIN)
    if kmount is not None:
        render = kmount.find(
            "activity.setContent { KayaAppearance { KayaTheme { "
            "KayaRoot() } } }")
        admit = kmount.find("admitSelftestOnFirstDraw(activity)")
        if render < 0 or admit < render \
                or "startSelftest(activity)" in kmount:
            fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
                 "starts the harness before first-draw admission")
    if kadmit is not None:
        admission_steps = [
            "addOnPreDrawListener(",
            "override fun onPreDraw(): Boolean",
            "removeOnPreDrawListener(this)",
            "startSelftest(activity)",
        ]
        admission_positions = [kadmit.find(step)
                               for step in admission_steps]
        if any(at < 0 for at in admission_positions) \
                or admission_positions != sorted(admission_positions) \
                or kadmit.count("ViewTreeObserver.OnPreDrawListener") \
                != 1 \
                or any(kadmit.count(step) != 1
                       for step in admission_steps):
            fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt "
                 "first-draw admission is not one-shot")

    scroll_ok = kotlin is not None and "fun scrollTarget(" not in kotlin
    if kotlin is not None:
        for verb, stop in [
            ("expect_overflow", "scroll_end"),
            ("scroll_end", "expect_at_end"),
            ("expect_at_end", "expect_selection"),
        ]:
            arm = section(kotlin, f'"{verb}" ->', f'"{stop}" ->',
                          TARGET_KOTLIN)
            scroll_ok = scroll_ok and arm is not None and (
                'target(spec, "scroll", KayaSceneModel.scrolls)' in arm)
    if not scroll_ok:
        fail("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt's "
             "three scroll arms do not share target()")

    return findings


def target_perturb(source_text, needle, replacement):
    """(doctored text, count) — the shell's replace-all with the count
    of occurrences, printed by the caller in its own words."""
    return (source_text.replace(needle, replacement),
            source_text.count(needle))


def target_watch(label, want, slot, source_text, needle, replacement,
                 finding):
    doctored, hits = target_perturb(source_text, needle, replacement)
    print(f"check-steps: keyed-target self-test {label} applied {hits} "
          f"substitution(s)")
    if hits != want:
        selftest_fail(f"{label} applied {hits} times, want {want} — an "
                      f"unchanged shadow cannot prove the rule fires")
    kwargs = {f"{slot}_src": doctored}
    out = target_surfaces(**kwargs)
    if not out:
        selftest_fail(f"{label} passed its doctored source")
    if "\n".join(out) != finding:
        print(f"check-steps: SELF-TEST FAIL ({label} failed for "
              f"another reason):", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        raise SystemExit(1)

target_out = target_surfaces()
if not target_out:
    H = read_rel(TARGET_HARNESS)
    S = read_rel(TARGET_SWIFT)
    K = read_rel(TARGET_KOTLIN)
    target_watch(
        "shared empty-segment wall", 1, "harness", H,
        "keys.is_empty() || keys.split('.').any(str::is_empty)",
        "keys.is_empty()",
        "check-steps: crates/kaya/src/harness.rs target grammar is not "
        "kind@id[key.path] with bare @ preserved")
    target_watch(
        "shared Stage key route", 1, "harness", H,
        "stage.resolve_id(t.kind, id, t.keys)",
        "stage.resolve_id(t.kind, id, None)",
        "check-steps: crates/kaya/src/harness.rs keyed targets do not "
        "carry keys through Stage::resolve_id")
    target_watch(
        "shared string-key wall", 1, "harness", H,
        "crate::wire::VALUE_STR => "
        "Some(std::str::from_utf8(payload).ok()?)",
        "crate::wire::VALUE_STR => None",
        "check-steps: crates/kaya/src/harness.rs table target matching "
        "is not string-key-only")
    target_watch(
        "shared keyed-stamp wall", 1, "harness", H,
        "if count == 0 || count >", "if count >",
        "check-steps: crates/kaya/src/harness.rs table stamps can "
        "resolve without copy keys")
    target_watch(
        "Swift indexed grammar", 1, "swift", S,
        'guard text.filter({ $0 == "#" }).count == 1 else '
        '{ return nil }',
        'guard text.contains("#") else { return nil }',
        "check-steps: swift/KayaSwiftUI.swift target grammar does not "
        "reject repeated or trailing #")
    target_watch(
        "Swift keyed-stamp wall", 1, "swift", S,
        "guard count > 0, count <=", "guard count <=",
        "check-steps: swift/KayaSwiftUI.swift table stamps can resolve "
        "without copy keys")
    target_watch(
        "Swift strict UTF-8", 1, "swift", S,
        "let key = String(bytes: tag[payload..<(payload + length)], "
        "encoding: .utf8)",
        "let key = String(bytes: tag[payload..<(payload + length)], "
        "encoding: .ascii)",
        "check-steps: swift/KayaSwiftUI.swift table stamp keys are not "
        "strict UTF-8")
    target_watch(
        "Swift sortTag route", 1, "swift", S,
        "kayaTableStamp($0.sortTag)?.node",
        "kayaTableStamp($0.tag)?.node",
        "check-steps: swift/KayaSwiftUI.swift keyed targets do not "
        "resolve through the table sortTag")
    target_watch(
        "Swift live-node filter", 1, "swift", S,
        "let live = registry.filter { kayaScene.nodes[$0.id] === $0 }",
        "let live = registry",
        "check-steps: swift/KayaSwiftUI.swift keyed targets do not "
        "filter destroyed registry entries")
    target_watch(
        "Swift earliest delimiter", 1, "swift", S,
        'switch String(spec.prefix { $0 != "#" && $0 != "@" })',
        'switch String(spec.split(separator: "#").first ?? "")',
        "check-steps: swift/KayaSwiftUI.swift target kind extraction "
        "does not stop at the earliest #/@")
    target_watch(
        "Swift direct startup admission", 1, "swift", S,
        "            kayaStartCommandPump()",
        "            kayaStartCommandPump()\n"
        "            kayaStartSelftest()",
        "check-steps: swift/KayaSwiftUI.swift starts the harness from "
        "primary onAppear before a mounted batch")
    target_watch(
        "Swift apply-boundary admission", 1, "swift", S,
        "    kayaDriveSelftestAdmission()",
        "    kayaStartSelftest()",
        "check-steps: swift/KayaSwiftUI.swift does not admit the "
        "harness at the completed apply-batch boundary")
    target_watch(
        "Swift terminal admission", 1, "swift", S,
        "if state == .started { return (.started, .none) }",
        "if state == .started { return (.started, .start) }",
        "check-steps: swift/KayaSwiftUI.swift selftest admission "
        "transition is not terminal, mounted-first, and singly armed")
    target_watch(
        "Swift mounted-batch admission", 1, "swift", S,
        "if mounted { return (.started, .start) }",
        "if mounted { return (.grace, .armGrace) }",
        "check-steps: swift/KayaSwiftUI.swift selftest admission "
        "transition is not terminal, mounted-first, and singly armed")
    target_watch(
        "Swift grace-expiry admission", 1, "swift", S,
        "return state == .grace ? (.started, .start) : (state, .none)",
        "return state == .grace ? (.grace, .none) : (state, .none)",
        "check-steps: swift/KayaSwiftUI.swift selftest admission "
        "transition is not terminal, mounted-first, and singly armed")
    target_watch(
        "Swift single grace timer", 1, "swift", S,
        "if state == .waiting && hasNodes { return (.grace, "
        ".armGrace) }",
        "if hasNodes { return (.grace, .armGrace) }",
        "check-steps: swift/KayaSwiftUI.swift selftest admission "
        "transition is not terminal, mounted-first, and singly armed")
    target_watch(
        "Swift state-before-effect admission", 1, "swift", S,
        "    kayaSelftestAdmissionState = next\n    switch effect {",
        "    switch effect {\n    kayaSelftestAdmissionState = next",
        "check-steps: swift/KayaSwiftUI.swift admission driver is not "
        "main-thread, state-before-effect, and bounded")
    target_watch(
        "Swift all-window immediate admission", 1, "swift", S,
        "let mounted = kayaScene.windows.values.contains(where: "
        "kayaWindowHasMountedContent)",
        "let mounted = kayaScene.windows[0]"
        ".map(kayaWindowHasMountedContent) ?? false",
        "check-steps: swift/KayaSwiftUI.swift selftest admission does "
        "not inspect every mounted surface")
    target_watch(
        "Swift all-surface mounted predicate", 1, "swift", S,
        "section.entries.contains(where: { $0.root != nil })", "false",
        "check-steps: swift/KayaSwiftUI.swift mounted-content "
        "predicate does not cover window, section, and navigation "
        "roots")
    target_watch(
        "Swift bounded diagnostic fallback", 1, "swift", S,
        "private let kayaSelftestUnmountedGrace: TimeInterval = 5.0",
        "private let kayaSelftestUnmountedGrace: TimeInterval = 120.0",
        "check-steps: swift/KayaSwiftUI.swift has no five-second "
        "all-surface fallback to the unmounted-scene diagnostic")
    target_watch(
        "Swift sections-only diagnostic", 1, "swift", S,
        "kayaScene.windows.values.allSatisfy({ "
        "!kayaWindowHasMountedContent($0) })",
        "kayaScene.windows.values.allSatisfy({ $0.root == nil && "
        "$0.sections.isEmpty })",
        "check-steps: swift/KayaSwiftUI.swift has no five-second "
        "all-surface fallback to the unmounted-scene diagnostic")
    target_watch(
        "Swift main-queue diagnosis snapshot", 1, "swift", S,
        "let unmountedNodeCount = DispatchQueue.main.sync { () -> "
        "Int? in",
        "let unmountedNodeCount = DispatchQueue.global().sync { () -> "
        "Int? in",
        "check-steps: swift/KayaSwiftUI.swift final unmounted "
        "diagnosis is not snapshotted on the main queue")
    target_watch(
        "Swift global start census", 1, "swift", S,
        "func kayaStartCommandPump() {",
        "kayaStartSelftest()\n\nfunc kayaStartCommandPump() {",
        "check-steps: swift/KayaSwiftUI.swift has 2 executable "
        "kayaStartSelftest() call(s), wanted 1")
    target_watch(
        "Compose sortTag route", 1, "kotlin", K,
        "tableStamp(it.sortTag)?.node", "tableStamp(it.tag)?.node",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt keyed targets do not resolve through the "
        "table sortTag")
    target_watch(
        "Compose indexed grammar", 1, "kotlin", K,
        "hash != spec.lastIndexOf('#')", "hash != hash",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt target grammar does not reject repeated or "
        "trailing #")
    target_watch(
        "Compose keyed-stamp wall", 1, "kotlin", K,
        "if (count == 0L || count > ((tag.size - 16) / 8).toLong()) "
        "return null",
        "if (count > ((tag.size - 16) / 8).toLong()) return null",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt table stamps can resolve without copy keys")
    target_watch(
        "Compose strict UTF-8", 1, "kotlin", K,
        ".onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)",
        ".onMalformedInput(java.nio.charset.CodingErrorAction.REPLACE)",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt table stamp keys are not strict UTF-8")
    target_watch(
        "Compose live-node filter", 1, "kotlin", K,
        "val live = registry.filter { KayaSceneModel.nodes[it.id] "
        "=== it }",
        "val live = registry",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt keyed targets do not filter destroyed "
        "registry entries")
    target_watch(
        "Compose earliest delimiter", 1, "kotlin", K,
        "val delimiter = spec.indexOfAny(charArrayOf('#', '@'))",
        "val delimiter = spec.indexOf('#')",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt target kind extraction does not stop at the "
        "earliest #/@")
    target_watch(
        "Compose shared scroll route", 3, "kotlin", K,
        'target(spec, "scroll", KayaSceneModel.scrolls)',
        "scrollTarget(spec)",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt's three scroll arms do not share target()")
    target_watch(
        "Compose first-draw admission", 1, "kotlin", K,
        "admitSelftestOnFirstDraw(activity)", "startSelftest(activity)",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt starts the harness before first-draw "
        "admission")
    target_watch(
        "Compose immediate admission", 1, "kotlin", K,
        "        decor.viewTreeObserver.addOnPreDrawListener(",
        "        startSelftest(activity); "
        "decor.viewTreeObserver.addOnPreDrawListener(",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt first-draw admission is not one-shot")
    target_watch(
        "Compose one-shot removal", 1, "kotlin", K,
        "                    decor.viewTreeObserver"
        ".removeOnPreDrawListener(this)",
        "                    Unit",
        "check-steps: android/kaya/src/main/kotlin/dev/kaya/"
        "KayaCompose.kt first-draw admission is not one-shot")
else:
    print("\n".join(target_out), file=sys.stderr)
    status = 1

# --- the Swift selftest-admission truth table, driven for real --------
if platform.system() == "Darwin":
    with tempfile.TemporaryDirectory() as admission_t:
        adm = pathlib.Path(admission_t)
        source = read_rel(TARGET_SWIFT)
        start = source.index(
            "enum KayaSelftestAdmissionState: Equatable")
        end = source.index("private var kayaSelftestAdmissionState",
                           start)
        (adm / "admission.swift").write_text(source[start:end],
                                             encoding="utf-8")

        def swiftc(*args):
            return subprocess.run(
                ["bash", "-c",
                 'source "$1/tools/lib/swift-toolchain.sh" && '
                 'cd "$1" && shift && kaya_swiftc "$@"',
                 "swift-toolchain", str(ROOT),
                 *[str(a) for a in args]], check=False).returncode

        if swiftc(adm / "admission.swift",
                  "tools/checks/swiftui-selftest-admission.swift",
                  "-o", adm / "admission-probe") != 0:
            print("check-steps: Swift selftest-admission probe did not "
                  "compile", file=sys.stderr)
            raise SystemExit(1)
        if subprocess.run([str(adm / "admission-probe")],
                          check=False).returncode != 0:
            print("check-steps: Swift selftest-admission truth table "
                  "failed", file=sys.stderr)
            raise SystemExit(1)

        adm_source = (adm / "admission.swift").read_text(
            encoding="utf-8")
        changes = (
            ("if state == .started { return (.started, .none) }",
             "if state == .started { return (.started, .start) }"),
            ("if mounted { return (.started, .start) }",
             "if mounted { return (.grace, .armGrace) }"),
            ("return state == .grace ? (.started, .start) : "
             "(state, .none)",
             "return state == .grace ? (.grace, .none) : "
             "(.started, .start)"),
            ("if state == .waiting && hasNodes { return (.grace, "
             ".armGrace) }",
             "if state == .waiting && hasNodes { return (.waiting, "
             ".none) }"),
            ("return (state, .none)", "return (.started, .start)"),
        )
        counts = []
        for needle, replacement in changes:
            counts.append(adm_source.count(needle))
            adm_source = adm_source.replace(needle, replacement)
        (adm / "admission-doctored.swift").write_text(
            adm_source, encoding="utf-8")
        admission_hits = " ".join(map(str, counts))
        print(f"check-steps: Swift selftest-admission runtime negative "
              f"applied {admission_hits} substitutions")
        if admission_hits != "1 1 1 1 1":
            selftest_fail("Swift admission runtime shadow was not "
                          "changed exactly once per branch")
        if swiftc(adm / "admission-doctored.swift",
                  "tools/checks/swiftui-selftest-admission.swift",
                  "-o", adm / "admission-doctored-probe") != 0:
            print("check-steps: Swift selftest-admission doctored "
                  "probe did not compile", file=sys.stderr)
            raise SystemExit(1)
        doctored_run = subprocess.run(
            [str(adm / "admission-doctored-probe")],
            capture_output=True, text=True, check=False)
        admission_out = doctored_run.stdout + doctored_run.stderr
        if doctored_run.returncode == 0:
            selftest_fail("doctored Swift admission truth table passed")
        for diagnostic in (
            "an empty initial model keeps waiting",
            "an unmounted node batch arms one grace period",
            "another unmounted batch does not arm a second timer",
            "a mounted initial batch starts immediately",
            "a mounted surface outranks an empty node census",
            "a later mount wins during grace",
            "grace expiry starts the diagnostic path",
            "a spurious expiry cannot start an empty model",
            "started is terminal",
        ):
            if diagnostic not in admission_out:
                print(f"check-steps: SELF-TEST FAIL (Swift admission "
                      f"shadow did not red '{diagnostic}')",
                      file=sys.stderr)
                print(admission_out, file=sys.stderr)
                raise SystemExit(1)
        print(f"check-steps: Swift selftest-admission truth table "
              f"watched red (exit {doctored_run.returncode})")
else:
    print("check-steps: Swift selftest-admission runtime truth table "
          "SKIPPED (needs Darwin swiftc)")

# The opening lint: a script must OPEN with an observation, giving
# every interpreter a bounded render retry before its first action.
# This is not Swift's transaction-admission wall: a vacuous expect can
# pass against an empty model, so Swift admits only after a completed
# mounted apply batch.
def opening_lint(text, path):
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        first = stripped.split(";")[0].split()
        verb = first[0] if first else ""
        if verb.startswith("expect"):
            return []
        return [f"{path}: opens with {verb!r} — the first step must be "
                f"an expect (its bounded retry lets rendering settle)"]
    return []


# The guard guards itself.
if not opening_lint('click button#0\nexpect label#0 "x"\n', "-"):
    selftest_fail("action-first script passed")

for p in STEPS:
    out = opening_lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} must open with an expect "
              f"(the retry lets rendering settle):", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1


# WHICH WIDTHS AN expect_split MAY SAMPLE. The backends' platform
# components disagree about where one pane becomes two — GNOME
# collapses below 400sp, Material wants 840dp, TwoPaneView sits between
# — so a width inside that band is legitimately one pane on one
# platform and two on another, and the scripts are compared
# byte-for-byte.
#
# THE TWO FORMS ARE POLICED DIFFERENTLY, by the claim each makes. A
# LITERAL (`expect_split "regular/split"`) names WHICH arm ran, so it
# needs a width the file itself set, outside the band. The BARE form
# asserts the invariant and is legal at a width the file never names —
# the only spelling a phone or tablet lane can run. A width the file
# DOES name must clear the band in either form: in there the invariant
# is not vacuous, it is WRONG.
def _width_lint(text, path, verb, low, high, band_sentence):
    width = None
    bad = []
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split()
        if parts[0] == "resize_window" and len(parts) > 1:
            m = re.match(r"([0-9]+)x([0-9]+)$", parts[1])
            width = int(m.group(1)) if m else None
        elif parts[0] == verb:
            bare = len(parts) == 1
            if width is None:
                if not bare:
                    what = ("a presentation" if verb == "expect_split"
                            else "positions")
                    bad.append(
                        f"{path}:{n}: {verb} names {what} with no "
                        f"preceding resize_window; a literal is a "
                        f"claim about the width, and a default window "
                        f"width is host-dependent. The bare form "
                        f"asserts the invariant instead and may run at "
                        f"a width the file never names.")
            elif low <= width < high:
                bad.append(f"{path}:{n}: {verb} at width {width}, "
                           f"inside the {low}..{high} band where "
                           f"platforms disagree {band_sentence}. "
                           f"Sample a width every platform agrees on.")
    return bad


def split_width_lint(text, path):
    # The band where the platforms legitimately disagree.
    return _width_lint(text, path, "expect_split", 400, 840,
                       "(GNOME collapses below 400sp, Material wants "
                       "840dp)")


def panes_width_lint(text, path):
    # The band where the platforms legitimately disagree about THREE
    # panes; the middle rung is deliberately unsampleable by a shared
    # scene — each lane's own gate holds its ladder
    # (tools/check-pane-ladder.sh on macOS).
    return _width_lint(text, path, "expect_panes", 400, 1400,
                       "about three panes (Material wants 1200dp, "
                       "GNOME 1075px at large text, the WinUI nest "
                       "more still)")


# The guard guards itself, all four directions.
if not split_width_lint(
        'expect_entries 0\nresize_window 500x600\n'
        'expect_split "regular/split"\n', "-"):
    selftest_fail("expect_split inside the band passed")
if not split_width_lint(
        "expect_entries 0\nresize_window 500x600\nexpect_split\n",
        "-"):
    selftest_fail("bare expect_split inside the band passed")
if not split_width_lint(
        'expect_entries 0\nexpect_split "regular/split"\n', "-"):
    selftest_fail("literal expect_split at an unnamed width passed")
if split_width_lint(
        'expect_entries 0\nresize_window 900x600\n'
        'expect_split "regular/split"\nresize_window 360x600\n'
        'expect_split "compact/stacked"\n', "-"):
    selftest_fail("agreed widths rejected")
if split_width_lint(
        "expect_entries 0\nexpect_split\nclick button#0\n"
        "expect_split\n", "-"):
    selftest_fail("bare expect_split at an unnamed width rejected")

for p in STEPS:
    out = split_width_lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} samples a width where "
              f"platforms disagree:", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1

# The guard guards itself, the same four directions as the split lint.
if not panes_width_lint(
        'expect_entries 0\nresize_window 700x600\n'
        'expect_panes "regular/1,2"\n', "-"):
    selftest_fail("expect_panes inside the band passed")
if not panes_width_lint(
        "expect_entries 0\nresize_window 700x600\nexpect_panes\n",
        "-"):
    selftest_fail("bare expect_panes inside the band passed")
if not panes_width_lint(
        'expect_entries 0\nexpect_panes "regular/0,1,2"\n', "-"):
    selftest_fail("literal expect_panes at an unnamed width passed")
if panes_width_lint(
        'expect_entries 0\nexpect_panes\nresize_window 1400x800\n'
        'expect_panes "regular/0,1,2"\nresize_window 360x600\n'
        'expect_panes "compact/2"\n', "-"):
    selftest_fail("agreed panes widths rejected")

for p in STEPS:
    out = panes_width_lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} samples a width where "
              f"platforms disagree about three panes:", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1


# THE LINUX STAGES MUST FIT EVERY RESIZE, and the lane's text scale
# must stay pinned. A resize wider than the Xvfb screen or the sway
# output leaves the window at whatever the compositor allowed — the
# breakpoints then legitimately show fewer panes and the leg reads as a
# backend bug rather than a small stage. And libadwaita's sp unit
# scales with the text factor (860sp is 1075px at large text), so a
# byte-frozen width is reproducible only while the factor is 1.0 —
# run-suites.sh unsets the env overrides, and this clause keeps both
# facts from quietly rotting (docs/multicolumn-plan.md D4).
def linux_stage_lint(step_files):
    runner = read_rel("tools/linux/run-suites.sh")
    stages = [int(m.group(1)) for m in
              re.finditer(r"-screen 0 (\d+)x\d+x24", runner)]
    stages += [int(m.group(1)) for m in
               re.finditer(r"output \* resolution (\d+)x\d+", runner)]
    bad = []
    if len(stages) < 2:
        bad.append("tools/linux/run-suites.sh: could not read both "
                   "protocol stages (the Xvfb -screen and sway output "
                   "lines moved) — this clause is blind")
    if "unset GDK_DPI_SCALE GDK_SCALE" not in runner:
        bad.append("tools/linux/run-suites.sh: the text-scale pin "
                   "(unset GDK_DPI_SCALE GDK_SCALE) is gone — sp-unit "
                   "breakpoints are then a different pixel width per "
                   "run and no byte-frozen resize is reproducible")
    widest = 0
    where = ""
    for path, text in step_files:
        for n, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if s.startswith("#"):
                continue
            m = re.match(r"resize_window\s+(\d+)x\d+", s)
            if m and int(m.group(1)) > widest:
                widest, where = int(m.group(1)), f"{path}:{n}"
    for stage in stages:
        if widest > stage:
            bad.append(f"{where}: resize_window to {widest} exceeds a "
                       f"linux stage of {stage}px — grow the Xvfb "
                       f"screen and the sway output in run-suites.sh, "
                       f"or the window silently stays small")
    return bad


# The guard guards itself, both directions: an oversized resize must be
# caught, and the real roster must pass.
if not linux_stage_lint([("huge.steps", "expect_entries 0\n"
                          "resize_window 9999x800\nexpect_panes\n")]):
    selftest_fail("a resize wider than the linux stages passed")


# EVERY TwoPaneView KILLS TALL MODE. TwoPaneView has a third mode no
# other backend can produce: at compact width on a window TALLER than
# 641, both panes stack top-over-bottom, the leading pane's WIDTH is
# applied as a HEIGHT, and the back affordance disappears — while
# expect_split reads "compact/split", which the bare invariant cannot
# refuse. Every scene height happens to be 600, so the lane's green
# rests on a 41-DIP coincidence unless every constructed view sets
# MinTallModeHeight to infinity (the platform's own off switch). A
# count, not a proximity match: the two must simply never diverge.
def tall_lint(text, path):
    made = text.count("TwoPaneView::new")
    killed = text.count("SetMinTallModeHeight")
    if made == 0:
        return [f"{path}: no TwoPaneView is constructed at all — the "
                f"split lowering moved and this clause is blind"]
    if killed < made:
        return [f"{path}: {made} TwoPaneView(s) constructed but only "
                f"{killed} SetMinTallModeHeight call(s) — a view "
                f"without one enters Tall mode on any tall-enough "
                f"compact window (docs/multicolumn-plan.md)"]
    return []


winui_text = read_rel("crates/kaya/src/winui/mod.rs")
tall_out = tall_lint(winui_text, "crates/kaya/src/winui/mod.rs")
if tall_out:
    print("\n".join(tall_out), file=sys.stderr)
    status = 1
# The guard guards itself: a doctored copy with one kill removed must
# fail, and the perturbation is PROVEN applied by the printed count.
tall_count = winui_text.count("SetMinTallModeHeight")
print(f"check-steps: tall self-test found {tall_count} kill call(s), "
      f"removing one")
if tall_count < 1:
    raise SystemExit(1)
tall_doctored = winui_text.replace("SetMinTallModeHeight",
                                   "XX_removed_XX", 1)
if not tall_lint(tall_doctored, "-"):
    selftest_fail("a TwoPaneView without the Tall kill passed")

stage_out = linux_stage_lint([(steps_rel(p), STEPS_TEXT[p])
                              for p in STEPS])
if stage_out:
    print("\n".join(stage_out), file=sys.stderr)
    print("check-steps: the linux stages cannot hold the scene roster "
          "(above)", file=sys.stderr)
    status = 1


# Raw CR bytes: the scripts are LF files by contract. The Swift
# interpreter splits script text on "\n", and Swift's grapheme-based
# split sees CRLF as ONE cluster — a CRLF-ended script would parse as
# a single giant line there while parsing fine everywhere else
# (docs/traps.md, the grapheme family). CR as DATA rides the \r
# escape, never a raw byte.
def cr_lint(data, path):
    if b"\r" in data:
        return [f"{path}: raw CR byte — steps files are LF-only "
                "(use the \\r escape for CR as data)"]
    return []


# The guard guards itself.
if not cr_lint(b'expect label#0 "x"\r\n', "-"):
    selftest_fail("CRLF sample passed")

for p in STEPS:
    out = cr_lint(p.read_bytes(), steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} contains a raw CR byte:",
              file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1


# Entries are single-line controls: what a platform does with an
# embedded line break in one is platform-defined input behavior (WinUI
# strips, GTK filters, others vary), so a scene asserting it would pin
# one platform's behavior against the rest. The multi-line round trip
# belongs to the textarea. set_text into an entry must not carry \n or
# \r.
def entry_newline_lint(text, path):
    bad = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for step in line.split(";"):
            s = step.strip()
            if re.match(r"set_text\s+entry#", s) \
                    and re.search(r"\\[nr]", s):
                bad.append(f"{path}:{lineno}: {s}")
    return bad


# The guard guards itself.
if not entry_newline_lint('set_text entry#0 "a\\nb"\n', "-"):
    selftest_fail("entry-newline sample passed")

for p in STEPS:
    out = entry_newline_lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} drives a line break into a "
              f"single-line entry (platform-defined; textarea owns the "
              f"multi-line contract):", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1

# THE TYPING VERB'S TWO RULES, both about `type` being REAL KEYSTROKES
# at the FOCUSED widget (harness.rs Step::Type, docs/undo-plan.md A8).
#
# 1. THE PAYLOAD IS PRINTABLE ASCII: the keycode mapping is only
#    platform-independent inside 0x20..0x7e, and Return is a COMMAND
#    whose meaning depends on the widget it lands in. harness.rs
#    refuses it at parse; this is the two-second answer with a file and
#    a line.
# 2. A SCRIPT THAT TYPES MUST HAVE ASSERTED FOCUS FIRST. The verb takes
#    no target, and because expects are bounded retries while actions
#    are not, that assertion is also the WAIT for focus to land.
def typing_lint(text, path):
    bad = []
    focused = False
    # The most recent `type` that is still the newest thing in the
    # focused field native undo history: (lineno, step, payload). Any
    # OTHER action pushes its own entry in front of it, which is why a
    # click clears this.
    pending = None
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for step in line.split(";"):
            s = step.strip()
            if not s:
                continue
            if s.startswith("expect_focused"):
                focused = True
                continue
            m = re.match(r'type\s+"(.*)"\s*$', s)
            if not m:
                # HOW MUCH OF A TYPED RUN ONE UNDO SPENDS IS FRONTIER
                # GRANULARITY, which a shared scene may not assert
                # (docs/undo-plan.md §2, §5.2). One character is the
                # floor every platform agrees on; more than one is a
                # coin toss. Measured: a five-character run undone in
                # one step passed on mac, where AppKit coalesces a
                # burst whole, and failed on linux/x11 where
                # GtkTextHistory spends one per undo.
                if re.match(r'menu_activate\s+"Edit>Undo"\s*$', s):
                    if pending is not None and len(pending[2]) > 1:
                        bad.append(
                            f"{path}:{pending[0]}: {pending[1]} — "
                            f"then line {lineno} undoes it. How much "
                            "of a MULTI character typed run one "
                            "Edit>Undo spends is frontier granularity, "
                            "which is platform flavored "
                            "(docs/undo-plan.md §5.2) and which "
                            "invariant 6 forbids a shared scene from "
                            "asserting. Type ONE character before an "
                            "undo that must restore the whole run, or "
                            "put an app action between them so the "
                            "undo spends THAT")
                    pending = None
                elif not s.startswith("expect") \
                        and not s.startswith("settle"):
                    # Anything else that acts — a click, a set_text,
                    # another menu — becomes the newest history entry
                    # itself.
                    pending = None
                continue
            payload = m.group(1)
            if re.search(r"\\[nrt]", payload) or not payload:
                bad.append(f"{path}:{lineno}: {s} — type carries real "
                           "keystrokes, and a line break is a COMMAND "
                           "whose meaning depends on the widget it "
                           "lands in (newline in a textarea, "
                           "activation in an entry). Type text, or "
                           "drive the command with its own verb")
            elif any(not (" " <= c <= "~") for c in payload):
                bad.append(f"{path}:{lineno}: {s} — type carries real "
                           "keystrokes, and one keycode per character "
                           "is only platform-independent inside "
                           "printable ASCII; composed characters are "
                           "an input method question, not a verb "
                           "argument")
            if not focused:
                bad.append(f"{path}:{lineno}: {s} — nothing has "
                           "asserted focus yet. type has no target: "
                           "whoever holds focus takes the keys, so a "
                           "script must expect_focused first (which is "
                           "also the WAIT for focus to land, since "
                           "actions are not retried)")
            pending = (lineno, s, payload)
    return bad


# The guard guards itself, every direction: a line break must fail, a
# composed character must fail, typing before focus is asserted must
# fail, and the well-formed shape must PASS — or the three above are
# failing for a reason that has nothing to do with what they claim.
if not typing_lint('expect_focused entry#0\ntype "a\\nb"\n', "-"):
    selftest_fail("a line break in a type payload passed")
if not typing_lint('expect_focused entry#0\ntype "héllo"\n', "-"):
    selftest_fail("a composed character in a type payload passed")
if not typing_lint('expect label#0 "x"\ntype "milk"\n', "-"):
    selftest_fail("typing before focus was asserted passed")
if typing_lint('expect_focused entry#0\ntype "milk 2"\n', "-"):
    selftest_fail("a well-formed type step was refused")
# The frontier-granularity clause, all four directions. The two PASSING
# shapes are the ones that make the failing one mean something: a
# one-character run is the floor every platform agrees on, and an app
# action between the typing and the undo makes the undo spend THAT.
if not typing_lint('expect_focused entry#0\ntype "tail"\n'
                   'expect_dirty true\nmenu_activate "Edit>Undo"\n',
                   "-"):
    selftest_fail("undoing a multi-character typed run passed")
if typing_lint('expect_focused entry#0\ntype "z"\nexpect_dirty true\n'
               'menu_activate "Edit>Undo"\n', "-"):
    selftest_fail("undoing a one-character run was refused")
if typing_lint('expect_focused entry#0\ntype "milk"\nclick button#0\n'
               'menu_activate "Edit>Undo"\n', "-"):
    selftest_fail("an app action between typing and undo was refused")
# AND THE CLAUSE MUST FIRE ON THE REAL FILE THAT PROVOKED IT: the
# perturbation goes into a COPY of editor.steps, the substitution count
# is printed and asserted, and an unchanged file is a FAILED test.
editor_text = read_rel("tools/scenes/editor.steps")
# The exact shape the lane caught: a multi-character run undone whole.
patched, applied = sub_first(r'^type "z"$', 'type " tail"',
                             editor_text, flags=re.M)
if applied != 1:
    print(f"check-steps: SELF-TEST FAIL (the undo-granularity "
          f"perturbation applied {applied} times, wanted 1 — "
          f"editor.steps was reshaped and this negative test is now "
          f"vacuous)", file=sys.stderr)
    raise SystemExit(1)
if not typing_lint(patched, "-"):
    selftest_fail("editor.steps with a multi-character run before "
                  "Edit>Undo passed the real file")


# ── expect_title MAY NOT SIT INSIDE A DIRTY STRETCH ──────────────────
#
# docs/dirty-plan.md §2. The declared title is untouched by `dirty` on
# every backend, but the WinUI arm composes its asterisk into the
# RENDERED CAPTION, which is exactly what expect_title reads there. So
# a title assertion made while the window is dirty reads "notes" on
# four lanes and "*notes" on the fifth.
#
# THE DIRTY STRETCH IS THE SCENE'S OWN CLAIM about itself: from an
# `expect_dirty true` up to the next `expect_dirty false`. A scene that
# never asserts `dirty` has no stretch and is untouched.
def title_dirty_lint(src, path):
    bad = []
    dirty = None
    dirty_line = 0
    for lineno, step in enumerate(src.split("\n"), start=1):
        s = step.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"expect_dirty\s+(true|false)\s*$", s)
        if m:
            dirty = m.group(1) == "true"
            dirty_line = lineno
            continue
        if s.startswith("expect_title") and dirty:
            bad.append(
                f"{path}:{lineno}: {s} — this window was claimed DIRTY "
                f"at line {dirty_line} and nothing has cleared the "
                "claim. The WinUI arm composes its unsaved-work "
                "asterisk into the RENDERED CAPTION, which is what "
                "expect_title reads there, so this line compares one "
                "string on four lanes and a marked one on the fifth "
                "(docs/dirty-plan.md D1 and its open question 2). Put "
                "an `expect_dirty false` in front of it: a title read "
                "is a five-lane byte comparison only once the scene "
                "has CLAIMED the window clean, and that claim is the "
                "only record a gate has")
    return bad


# Both directions, because a guard that only ever passes is not a
# guard: a title read inside the stretch must FAIL, and the same read
# after the mark comes down must PASS.
if not title_dirty_lint('expect_dirty true\nexpect_title "notes"\n',
                        "-"):
    selftest_fail("expect_title inside a dirty stretch passed")
if title_dirty_lint('expect_dirty true\nexpect_dirty false\n'
                    'expect_title "notes"\n', "-"):
    selftest_fail("expect_title after the mark cleared was refused")
if title_dirty_lint('expect_title "window probe"\n', "-"):
    selftest_fail("a scene with no dirty claim at all was refused")
# AND ON THE REAL FILE THAT NEEDS IT: the perturbation moves
# editor.steps' own launch title read to just after an `expect_dirty
# true`, the substitution count is printed and asserted, and an
# unchanged file is a FAILED test.
patched, applied = sub_first(
    r"^expect_dirty true$",
    'expect_dirty true\nexpect_title "notes"', editor_text, flags=re.M)
if applied != 1:
    print(f"check-steps: SELF-TEST FAIL (the title/dirty perturbation "
          f"applied {applied} times, wanted 1 — editor.steps no longer "
          f"claims a dirty stretch and this negative test is now "
          f"vacuous)", file=sys.stderr)
    raise SystemExit(1)
if not title_dirty_lint(patched, "-"):
    selftest_fail("editor.steps with a title read inside a dirty "
                  "stretch passed the real file")


# ── TWO ALERTS WITH THE SAME TITLE NEED `expect_alerts 0` BETWEEN ────
#
# MEASURED 2026-08-10 on the iOS lane, with editor.steps. The app
# guards unsaved work at three doors under one alert title, so
# `expect_alert "unsaved changes"` cannot tell a NEW dialog from the
# one still on screen. The stretch that failed:
#
#   alert_choose cancel
#   expect textarea#0 "scratch"   <- already true; passes instantly
#   expect_dirty true             <- already true; passes instantly
#   menu_activate "File>New"
#   expect_alert "unsaved changes" <- matched the OLD alert, +0ms
#
# and the app's second show hit the core's one-alert-per-process
# assertion and ABORTED the guest.
#
# WHAT THIS CLAUSE DELIBERATELY DOES NOT CATCH, because a guard that
# fires on correct scripts gets deleted rather than obeyed. Two
# conditions have to meet for the race to exist:
#
#  1. THE TITLES REPEAT. A stale "delete item?" can never satisfy
#     `expect_alert "eject disk?"`.
#  2. THE ANSWER WAS `cancel`. An ACTION's continuation does something
#     the script can wait on; a CANCEL's continuation is by
#     construction "leave everything as it was", so every assertion
#     after it was already true before the dialog opened.
#
# So the clause fires on a cancel answered into a repeat of its own
# title, the measured case and nothing wider.
def alert_wait_lint(src, path):
    bad = []
    cancelled = None         # (line, title) of the last CANCELLED alert
    seen = None              # the title expect_alert last matched
    for lineno, step in enumerate(src.split("\n"), start=1):
        s = step.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r'expect_alert\s+"(.*)"\s*$', s)
        if m:
            if cancelled and cancelled[1] == m.group(1):
                bad.append(
                    f"{path}:{lineno}: {s} — the alert CANCELLED at "
                    f"line {cancelled[0]} carries the SAME title and "
                    "nothing has asserted it is gone. expect_alert "
                    "matches by title, so this line can be satisfied "
                    "by the dialog still on screen; the app then shows "
                    "its next one into a live slot and the core aborts "
                    "the guest (\"alert N is already live — one alert "
                    "per process\"). Put `expect_alerts 0` between "
                    "them: a cancel changes nothing, so every other "
                    "assertion here was already true and only the "
                    "dialog count can be the wait")
            seen = m.group(1)
            continue
        if re.match(r"expect_alerts\s+0\s*$", s):
            cancelled = None
            seen = None
            continue
        m = re.match(r"alert_choose\s+(\S+)\s*$", s)
        if m:
            cancelled = ((lineno, seen) if m.group(1) == "cancel"
                         else None)
    return bad


# Every direction. The cancelled repeat must FAIL; the same pair with
# the count assertion between must PASS; a repeat after an ACTION must
# pass (its continuation is waitable — confirm.steps); and two
# DIFFERENT titles must pass.
if not alert_wait_lint('expect_alert "x"\nalert_choose cancel\n'
                       'expect_alert "x"\n', "-"):
    selftest_fail("a cancelled same-title repeat with no wait passed")
if alert_wait_lint('expect_alert "x"\nalert_choose cancel\n'
                   'expect_alerts 0\nexpect_alert "x"\n', "-"):
    selftest_fail("a same-title repeat behind expect_alerts 0 was "
                  "refused")
if alert_wait_lint('expect_alert "x"\nalert_choose 0\n'
                   'expect_alert "x"\n', "-"):
    selftest_fail("a same-title repeat after an ACTION was refused")
if alert_wait_lint('expect_alert "x"\nalert_choose cancel\n'
                   'expect_alert "y"\n', "-"):
    selftest_fail("two DIFFERENT alert titles were refused")
# AND ON THE REAL FILE THAT PROVOKED IT: delete editor.steps' first
# `expect_alerts 0` and the lint must catch what the iOS lane caught.
patched, applied = sub_first(r"^expect_alerts 0\n", "", editor_text,
                             flags=re.M)
if applied != 1:
    print(f"check-steps: SELF-TEST FAIL (the alert-wait perturbation "
          f"applied {applied} times, wanted 1 — editor.steps no longer "
          f"spells the wait and this negative test is now vacuous)",
          file=sys.stderr)
    raise SystemExit(1)
if not alert_wait_lint(patched, "-"):
    selftest_fail("editor.steps with its alert wait deleted passed the "
                  "real file")

for p in STEPS:
    out = typing_lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} types in a way no keyboard "
              f"can:", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1
    out = title_dirty_lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} asserts a window title "
              f"while the window is dirty:", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1
    out = alert_wait_lint(STEPS_TEXT[p], steps_rel(p))
    if out:
        print(f"check-steps: {steps_rel(p)} reopens a same-titled "
              f"alert with no wait:", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1

# Every scene script must be reachable by name. An unregistered scene
# does not fail — it silently runs a DIFFERENT script, and a leg that
# passes then proves nothing about the scene it claims to be.
#
# Every scene must be WIRED into every platform runner, not merely
# registered: a scene can exist, parse and be registered yet run
# nowhere. EVERY runner is held to a STRUCTURAL signature — mac and
# linux to their leg spellings, windows, iOS and android to membership
# in the lane modules their legs are generated from. NEVER the bare
# name: the name-level check this
# replaced was satisfied by a COMMENT (the only `background` in
# run-sim.sh sat in a sentence about shell jobs) and by unrelated CODE
# (`window` inside resize_window), so four pairs claimed wiring that
# did not exist — found by the 2026-08-19 comment sweep's gate survey.
#
# A runner may DECLARE a scene off instead: *_DESKTOP_ONLY_SCENES for
# platform policy, IOS_UNWIRED_SCENES for ledgered gaps. Declarations
# are checked too — one that names a scene the roster lacks, or a
# scene that is ALSO wired, is a red, so a stale declaration cannot
# linger.
#
# EXCEPT where the backend says it has not got there yet: a backend
# left behind by a depth slice declares `depth_stub("<scene>")`, the
# same call check-stubs reads from the other side. Between them the
# two gates state one rule: a scene's legs are wired on a runner IF
# AND ONLY IF that runner's backend has the feature.
#
# THE EXEMPTION IS KEYED ON THE SCENE'S FEATURES, NOT ITS NAME, or the
# two gates contradict each other. A scene can demand a feature it is
# not named after — `todos.steps` activates Edit>Undo — so a stub on
# `undo` that held only the `undo` legs off a runner would leave no
# tree able to satisfy both gates. tools/lib/scene-features.py derives
# the pairs and is the SAME predicate the cross-check uses.
def wired():
    r = subprocess.run(
        ["python3", "tools/lib/scene-features.py", "--mode", "exempt"],
        cwd=ROOT, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        print("check-steps: scene-features.py could not derive the "
              "depth-stub exemptions", file=sys.stderr)
        return 1
    exempt = {tuple(line.split("\t"))
              for line in r.stdout.splitlines() if line.strip()}

    # The iOS roster is the lane MODULE's since the runner conversion:
    # every suite's scenes plus the declared-off lists come from the
    # import, and the hand-queued regex died with the shell text (the
    # rust suite is a module-driven loop now too).
    ios_wired = sorted(ios_lane.wired_scenes())
    ios_declared = sorted(set(ios_lane.DESKTOP_ONLY_SCENES)
                          | set(ios_lane.UNWIRED_SCENES))
    android_wired = sorted(android_lane.wired_scenes())
    android_declared = sorted(set(android_lane.DESKTOP_ONLY_SCENES)
                              | set(android_lane.UNWIRED_SCENES))
    # A reader that reads nothing agrees with everything.
    if not ios_wired:
        print("check-steps: wired() read NO scenes out of the ios lane "
              "module's suite lists — they moved, and this clause "
              "is blind", file=sys.stderr)
        return 1
    if not android_wired:
        print("check-steps: wired() read NO scenes out of the android "
              "lane module's suite lists — they moved, and this "
              "clause is blind", file=sys.stderr)
        return 1

    roster = {p.stem for p in STEPS}
    failed = 0
    for decl in ios_declared:
        if decl not in roster:
            print(f'check-steps: the ios lane module declares "{decl}" '
                  f"off, but no such scene exists", file=sys.stderr)
            failed = 1
        if decl in ios_wired:
            print(f'check-steps: the ios lane module declares "{decl}" '
                  f"off AND a suite lists it — one of the two is "
                  f"stale", file=sys.stderr)
            failed = 1
    for decl in android_declared:
        if decl not in roster:
            print(f'check-steps: the android lane module declares '
                  f'"{decl}" off, but no such scene exists',
                  file=sys.stderr)
            failed = 1
        if decl in android_wired:
            print(f'check-steps: the android lane module declares '
                  f'"{decl}" off AND a suite lists it — one of the two '
                  f"is stale", file=sys.stderr)
            failed = 1

    runner_texts = {
        "tools/linux/run-suites.sh":
            read_rel("tools/linux/run-suites.sh"),
        # The windows, ios, android and mac rosters are read from the
        # lane MODULES, not text; the keys match scene-features.py's
        # RUNNERS rows so the depth-stub exemptions line up.
        "tools/lib/lanes/win.py": "",
        "tools/lib/lanes/ios.py": "",
        "tools/lib/lanes/android.py": "",
        "tools/lib/lanes/mac.py": "",
    }
    win_scenes = {win_lane.scene_lang(leg)[0] for leg in win_lane.legs()}
    mac_wired = mac_lane.wired_scenes()
    if not mac_wired:
        print("check-steps: wired() read NO scenes out of the mac lane "
              "module's queue — it moved, and this clause is blind",
              file=sys.stderr)
        return 1
    for p in STEPS:
        scene = p.stem
        for runner, text in runner_texts.items():
            if (runner, scene) in exempt:
                continue
            if runner == "tools/lib/lanes/ios.py":
                ok = scene in ios_wired or scene in ios_declared
                if not ok:
                    print(f'check-steps: scene "{scene}" has no leg in '
                          f"the ios lane module and is not declared "
                          f"off ({runner})", file=sys.stderr)
                    failed = 1
            elif runner == "tools/lib/lanes/android.py":
                # milestone2 needs no special case here: the bare suite
                # legs map to it through the module's own scene_of.
                ok = (scene in android_wired
                      or scene in android_declared)
                if not ok:
                    print(f'check-steps: scene "{scene}" has no leg in '
                          f"the android lane module and is not "
                          f"declared off ({runner})", file=sys.stderr)
                    failed = 1
            elif runner == "tools/lib/lanes/win.py":
                if scene not in win_scenes:
                    print(f'check-steps: scene "{scene}" has no leg in '
                          f"the win lane module ({runner})",
                          file=sys.stderr)
                    failed = 1
            elif runner == "tools/lib/lanes/mac.py":
                if scene not in mac_wired:
                    print(f'check-steps: scene "{scene}" has no leg in '
                          f"the mac lane module ({runner})",
                          file=sys.stderr)
                    failed = 1
            else:
                sig = f'run "$proto" {scene}-'
                if scene == "milestone2":
                    sig = scene
                if sig not in text:
                    print(f'check-steps: scene "{scene}" has no live '
                          f'legs in {runner} (wanted "{sig}")',
                          file=sys.stderr)
                    failed = 1
    return failed


if wired():
    status = 1


# THE ACCESSIBILITY BUS IS PART OF A LEG'S WIRING, on the one lane that
# has to supply it. GTK publishes its tree over libdbus, which
# AUTOLAUNCHES a session bus on X11 and needs no environment variable;
# the harness READS that tree with the atspi/zbus crate, which finds a
# session bus ONLY in DBUS_SESSION_BUS_ADDRESS. A plain leg exports
# none, so publisher and reader land on different busses and every ax
# read answers "<not in the accessibility tree>" — silently on x11,
# behind a Gtk-WARNING about autolaunch on wayland.
# tools/linux/a11y-leg.sh is what reconciles them: `eval $(dbus-launch
# --sh-syntax)` puts the address in the environment.
#
# NOTHING ELSE CAN SEE THIS. The sentence names a missing NODE, so it
# reads as a scene or lowering bug and sends the reader to the widget;
# the scene passes on every other platform; and the leg is red from
# the commit that wired it, so there is no regression to bisect.
# Measured 2026-08-27 on the canvas leg — the fourteenth ax-asserting
# scene and the only one wired without a bus (docs/traps.md).
#
# The bus-reading METHODS are pinned against gtk.rs rather than listed
# here alone: a sixth one must name its verb or this gate quietly
# stops covering the scenes that use it.
AX_VERB = {
    "ax": "expect_ax",
    "ax_hint": "expect_ax_hint",
    "highlights": "expect_highlights",
    "selection": "expect_selection",
    "revealed": "expect_revealed",
}


def ax_bus(root):
    root = pathlib.Path(root)
    bad = []

    gtk = (root / "crates/kaya/src/gtk.rs").read_text(
        encoding="utf-8").splitlines()
    readers = set()
    for i, line in enumerate(gtk):
        if "atspi_collect(" not in line \
                and "atspi_range_read(" not in line:
            continue
        for j in range(i, -1, -1):
            m = re.match(r"\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?"
                         r"fn\s+(\w+)", gtk[j])
            if m:
                readers.add(m.group(1))
                break
    readers -= {"atspi_collect", "atspi_range_read"}
    # A reader that read nothing agrees with everything.
    if not readers:
        bad.append("check-steps: no caller of "
                   "atspi_collect/atspi_range_read found in gtk.rs — "
                   "the bus readers moved and this clause is blind")
    for r in sorted(readers - set(AX_VERB)):
        bad.append(f'check-steps: gtk.rs method "{r}" reads the '
                   "accessibility bus but AX_VERB does not name its "
                   ".steps verb — add it, or every scene using that "
                   "verb loses its bus-wiring check")

    lines = (root / "tools/linux/run-suites.sh").read_text(
        encoding="utf-8").splitlines()
    legs = {}
    for i, line in enumerate(lines):
        m = re.match(r'\s*run\s+"\$proto"\s+([A-Za-z0-9_-]+)', line)
        if not m:
            continue
        chunk, j = line, i
        while chunk.rstrip().endswith("\\") and j + 1 < len(lines):
            j += 1
            chunk += lines[j]
        legs[m.group(1)] = chunk
    if len(legs) < 100:
        bad.append(f"check-steps: read only {len(legs)} legs out of "
                   'run-suites.sh — the leg spelling moved away from '
                   '`run "$proto" <name>` and this clause is blind')

    scenes = sorted((root / "tools/scenes").glob("*.steps"))
    ax_scenes = []
    for p in scenes:
        body = p.read_text(encoding="utf-8")
        verbs = sorted({v for v in AX_VERB.values()
                        if re.search(r"^\s*" + v + r"\b", body, re.M)})
        if verbs:
            ax_scenes.append((p.stem, verbs))
    if not ax_scenes:
        bad.append("check-steps: no scene asserts any ax-family verb — "
                   "the verbs were renamed and this clause is blind")

    for scene, verbs in ax_scenes:
        mine = {n: c for n, c in legs.items()
                if n == scene or n.startswith(scene + "-")}
        if not mine:
            bad.append(f'check-steps: scene "{scene}" asserts '
                       f"{verbs[0]} but has no `run \"$proto\" "
                       f"{scene}-` leg in run-suites.sh")
            continue
        for name, cmd in sorted(mine.items()):
            if "tools/linux/a11y-leg.sh" in cmd:
                continue
            bad.append(
                f'check-steps: linux leg "{name}" runs a scene '
                f"asserting {', '.join(verbs)} but does NOT go through "
                "tools/linux/a11y-leg.sh. GTK publishes the tree onto "
                "an autolaunched session bus that the harness's zbus "
                "reader cannot find, so every ax read answers "
                '"<not in the accessibility tree>" on both protocols '
                "(the traps entry on the a11y session bus)")
    return bad


ax_out = ax_bus(ROOT)
if ax_out:
    print("\n".join(ax_out), file=sys.stderr)
    status = 1


# Watched negatives. Doctored COPIES of the real files — never the
# tree — with the substitution count printed, because a perturbation
# that did not apply is a test that passed vacuously.
def ax_bus_selftest(label, want, doctor):
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        (d / "tools/linux").mkdir(parents=True)
        (d / "crates/kaya/src").mkdir(parents=True)
        shutil.copytree(ROOT / "tools/scenes", d / "tools/scenes")
        shutil.copy(ROOT / "tools/linux/run-suites.sh",
                    d / "tools/linux/run-suites.sh")
        shutil.copy(ROOT / "crates/kaya/src/gtk.rs",
                    d / "crates/kaya/src/gtk.rs")
        if not doctor(d):
            print(f'check-steps: ax_bus self-test "{label}" could not '
                  f"doctor its copy", file=sys.stderr)
            return False
        out = ax_bus(d)
        if not out:
            print(f'check-steps: ax_bus self-test "{label}" PASSED a '
                  f"tree it must refuse", file=sys.stderr)
            return False
        if any(want in b for b in out):
            return True
        print(f'check-steps: ax_bus self-test "{label}" refused, but '
              f'not for the stated reason (wanted "{want}"):',
              file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        return False


# 1. THE SHIPPED BUG ITSELF: the canvas leg as ee7bc41 wired it, with
#    no a11y-leg.sh. It must be refused, and it must NAME canvas-rust.
def ax_bus_doctor_canvas(d):
    p = d / "tools/linux/run-suites.sh"
    src = p.read_text(encoding="utf-8")
    old = ('run "$proto" canvas-rust env KAYA_SELFTEST=canvas \\\n'
           '        tools/linux/a11y-leg.sh '
           '"$CARGO_TARGET_DIR/debug/examples/canvas"')
    new = ('run "$proto" canvas-rust env KAYA_SELFTEST=canvas \\\n'
           '        "$CARGO_TARGET_DIR/debug/examples/canvas"')
    n = src.count(old)
    print(f"  ax_bus self-test 1: un-wired the canvas leg's bus, {n} "
          f"substitution(s)")
    if n != 1:
        return False
    p.write_text(src.replace(old, new), encoding="utf-8")
    return True


if not ax_bus_selftest("the canvas leg with no bus",
                       'leg "canvas-rust"', ax_bus_doctor_canvas):
    status = 1


# 2. THE SAME DEFECT ON A SCENE NOBODY WOULD SUSPECT: a11y-rust itself.
def ax_bus_doctor_a11y(d):
    p = d / "tools/linux/run-suites.sh"
    out, n = sub_count(
        r'(run "\$proto" a11y-rust env KAYA_SELFTEST=a11y \\\n\s*)'
        r"tools/linux/a11y-leg\.sh ", r"\1",
        p.read_text(encoding="utf-8"))
    print(f"  ax_bus self-test 2: un-wired the a11y-rust leg's bus, "
          f"{n} substitution(s)")
    if n != 1:
        return False
    p.write_text(out, encoding="utf-8")
    return True


if not ax_bus_selftest("the a11y leg with no bus", 'leg "a11y-rust"',
                       ax_bus_doctor_a11y):
    status = 1


# 3. A SIXTH BUS READER, unnamed by AX_VERB — the way this gate goes
#    blind.
def ax_bus_doctor_reader(d):
    p = d / "crates/kaya/src/gtk.rs"
    src = p.read_text(encoding="utf-8")
    anchor = ("fn atspi_collect(want: atspi::Role, index: usize, "
              "want_description: bool)")
    n = src.count(anchor)
    print(f"  ax_bus self-test 3: spliced a sixth bus reader, {n} "
          f"anchor(s)")
    if n != 1:
        return False
    p.write_text(src.replace(
        anchor,
        "fn landmarks(&self, target: crate::harness::Target) -> "
        "String {\n"
        "    atspi_collect(atspi::Role::Landmark, 0, false)"
        ".unwrap_or_default()\n"
        "}\n\n" + anchor, 1), encoding="utf-8")
    return True


if not ax_bus_selftest("a bus reader AX_VERB does not name",
                       'method "landmarks"', ax_bus_doctor_reader):
    status = 1


# THE VERB-FEATURE CROSS-CHECK — the other half of the same predicate.
# wired() above says when a stub HOLDS legs off a runner; this says
# when a runner runs legs it must not, i.e. a scene whose verbs demand
# a feature its backend still refuses. Keyed on the scene NAME that
# question cannot be asked at all: a scene's name is not what a backend
# has to implement.
#
# tools/lib/scene-features.py holds the derivation (verbs and menu
# ROLES to features, with the role table pinned against MENU_ROLES so
# a seventh role cannot ship without an answer).
if subprocess.run(["python3", "tools/lib/scene-features.py", "--mode",
                   "check"], cwd=ROOT, check=False).returncode != 0:
    status = 1


# The guard guards itself against a REAL scene corpus: the synthetic
# root borrows tools/scenes, scene.rs and hand-rolled-stubs.py from
# this tree and synthesizes only the runner and backend files, so the
# derivation under test is the derivation that ships.
def feature_selftest(scene, stub, extra=""):
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        for sub in ("tools/lib/lanes", "tools/linux", "tools/ios",
                    "crates/kaya/src", "swift",
                    "crates/kaya/src/winui",
                    "android/kaya/src/main/kotlin/dev/kaya"):
            (d / sub).mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / "tools/scenes", d / "tools/scenes")
        shutil.copy(ROOT / "crates/kaya/src/scene.rs",
                    d / "crates/kaya/src/scene.rs")
        shutil.copy(ROOT / "tools/lib/hand-rolled-stubs.py",
                    d / "tools/lib/hand-rolled-stubs.py")
        for empty in ("tools/linux/run-suites.sh",
                      "crates/kaya/src/gtk.rs",
                      "crates/kaya/src/winui/mod.rs",
                      "swift/KayaSwiftUI.swift"):
            (d / empty).write_text("", encoding="utf-8")
        # The lane modules are IMPORTED with a roster floor, so the
        # fixture's "runner that runs nothing" is a module whose
        # scenes are real enough to pass the floor and match nothing.
        for lane_stub in ("tools/lib/lanes/win.py",
                          "tools/lib/lanes/ios.py",
                          "tools/lib/lanes/mac.py"):
            (d / lane_stub).write_text(
                "def wired_scenes():\n"
                "    return {f'zzfixture{i}' for i in range(12)}\n",
                encoding="utf-8")
        if extra:
            (d / "tools/scenes/zzprobe.steps").write_text(
                f'expect label#0 "x"\n{extra}\n', encoding="utf-8")
        # The android roster is a lanes module too: the fixture wires
        # exactly one real scene, padded past the import floor.
        (d / "tools/lib/lanes/android.py").write_text(
            "def wired_scenes():\n"
            f"    return {{{scene!r}}} | "
            "{f'zzfixture{i}' for i in range(11)}\n",
            encoding="utf-8")
        (d / "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
         ).write_text(stub + "\n", encoding="utf-8")
        r = subprocess.run(
            ["python3", str(ROOT / "tools/lib/scene-features.py"),
             "--root", str(d), "--mode", "check"],
            capture_output=True, text=True, check=False)
        return r.returncode, r.stdout + r.stderr


# 1. THE EXACT SHAPE §8 RECORDS: the android runner running todos while
#    Compose stubs undo. It must fail, and it must NAME todos — a
#    message naming only `undo` would send the reader to the scene that
#    is not the problem, and the whole defect was that nobody was
#    looking at todos.
rc, selftest_out = feature_selftest(
    "todos", 'internal fun x(): Nothing = depthStub("undo")')
if rc == 0 or not re.search(
        r'runs "todos" legs[\s\S]*stubs "undo"[\s\S]*todos\.steps:',
        selftest_out):
    print("check-steps: SELF-TEST FAIL (a todos leg on a backend "
          "stubbing undo was not named):", file=sys.stderr)
    print(selftest_out, file=sys.stderr)
    raise SystemExit(1)
# 2. ...and the SAME stub with the legs pulled must PASS, or the
#    interim state of a depth slice is inexpressible and this clause is
#    a wall across the only road out of it.
rc, _ = feature_selftest(
    "menus", 'internal fun x(): Nothing = depthStub("undo")')
if rc != 0:
    selftest_fail("a stub with no legs wired was refused")
# 3. ...and with no stub at all, the same legs must PASS — otherwise 1
#    is failing for some reason that has nothing to do with the stub.
rc, _ = feature_selftest("todos", "")
if rc != 0:
    selftest_fail("todos legs on an unstubbed backend were refused")
# 4/5. THE CLIPBOARD ROWS FIRING CROSS-SCENE, which nothing in the tree
#    can show: `clipboard.steps` is NAMED after the feature it needs,
#    so a dead verb row and a live one look identical from outside. A
#    probe scene carries the verb under a name that implies nothing,
#    and each derivation gets its own run — the VERB row and the ROLE
#    row.
for probe in ('expect_clipboard text "x"', 'menu_activate '
              '"Edit>Paste"'):
    rc, selftest_out = feature_selftest(
        "zzprobe",
        'internal fun x(): Nothing = depthStub("clipboard")', probe)
    if rc == 0 or not re.search(
            r'runs "zzprobe" legs[\s\S]*stubs "clipboard"',
            selftest_out):
        print(f"check-steps: SELF-TEST FAIL (a clipboard rule did not "
              f"fire for: {probe})", file=sys.stderr)
        print(selftest_out, file=sys.stderr)
        raise SystemExit(1)

# The Android per-leg setup has an ORDER, and every step's place
# matters — enabling the accessibility service before the force-stop
# kills it, and before the logcat clear erases the evidence it
# started. None of that is visible at the call site, and the failure
# surfaces much later as "the picker never appeared".
if subprocess.run(["python3", "tools/lib/android-leg-order.py"],
                  cwd=ROOT, check=False).returncode != 0:
    status = 1

# SCENES MEANS "THE LANGUAGE SWEEP LANDED". Each desktop runner derives
# its mechanical per-scene surfaces from SCENES — the source scp, the
# taskkill list — so a rust-only scene added there sends the runner
# looking for guests that do not exist. DEPTH_SCENES is the variable
# for that case, in all three runners.
def sweep_guests():
    LANGS = [
        ("go", "guests/go/{s}/{s}.go"),
        ("python", "guests/python/{s}.py"),
        ("js", "guests/js/{s}.ts"),
        ("csharp", "guests/csharp/{S}Scene.cs"),
        ("swift", "guests/swift/{s}.swift"),
        ("ocaml", "guests/ocaml/{s}.ml"),
        ("haskell", "guests/haskell/{s}.hs"),
    ]
    # The JVM and CLR guests are NOT one file per scene: one package
    # plus a selector with irregular class names, so a path pattern
    # cannot see them. Check what decides reachability — that the
    # selector dispatches it. A class wired into no switch is as broken
    # as a missing file.
    SELECTORS = [
        ("java",
         "guests/java-desktop/dev/kaya/milestone2kt/Main.java"),
        ("csharp", "guests/csharp/Program.cs"),
    ]
    def desktop_scene_lists():
        """(runner, SCENES-or-None) for the three desktop lanes — the
        mac and windows lists are the lane modules', imported rather
        than regexed, so they cannot drift from what the runners
        stage."""
        out = [("tools/lib/lanes/mac.py", list(mac_lane.SCENES))]
        for runner in ("tools/linux/run-suites.sh",):
            m = re.search(r'^SCENES="([^"]+)"', read_rel(runner), re.M)
            out.append((runner, m.group(1).split() if m else None))
        out.append(("tools/lib/lanes/win.py", list(win_lane.SCENES)))
        return out

    bad = []
    for runner, listed in desktop_scene_lists():
        if listed is None:
            bad.append(f"{runner}: no SCENES variable")
            continue
        for scene in listed:
            for lang, pat in LANGS:
                rel = pat.format(s=scene, S=scene.capitalize())
                if not (ROOT / rel).exists():
                    bad.append(
                        f'{runner}: scene "{scene}" is in SCENES but '
                        f"has no {lang} guest ({rel}) — a rust-only "
                        f"scene belongs in DEPTH_SCENES")
    scenes = set()
    for _runner, listed in desktop_scene_lists():
        if listed:
            scenes.update(listed)
    for lang, selector in SELECTORS:
        text = read_rel(selector)
        for scene in sorted(scenes):
            # milestone2 is the DEFAULT arm in both selectors,
            # reachable without a case of its own — verified, not
            # assumed: both files end in `default:` dispatching
            # Milestone2.
            if scene == "milestone2":
                continue
            if f'case "{scene}"' not in text:
                bad.append(
                    f'{selector}: scene "{scene}" is in SCENES but the '
                    f"{lang} selector never dispatches it — the guest "
                    f"is unreachable")
    # A GUEST THAT EXISTS BUT NO LEG RUNS IS INVISIBLE TO EVERY OTHER
    # GATE: wired() above demands only that a scene has SOME leg, so
    # one language covers for all of them.
    #
    # mac only, deliberately: this lane names every leg
    # `<scene>-<lang>-swiftui`, so the expectation is exact — and it
    # is the lane MODULE's leg list now, with a floor, closing the
    # bare `if m:` vacuity the stage-1 record flagged. The other
    # runners have their own naming and their own backend-stub
    # carve-outs.
    mac_leg_names = {name for name, _s, _l in mac_lane.legs()}
    if len(mac_leg_names) < 100:
        bad.append(f"tools/lib/lanes/mac.py: the mac queue lists "
                   f"{len(mac_leg_names)} legs — a roster that small "
                   f"is a moved table, and this sweep would agree "
                   f"with anything")
        return bad
    stubbed = read_rel("swift/KayaSwiftUI.swift")
    for scene in mac_lane.SCENES:
        if f'epthStub("{scene}", on: "macos")' in stubbed:
            continue
        for lang, pat in LANGS + [("rust", "guests/rust/{s}.rs")]:
            rel = pat.format(s=scene, S=scene.capitalize())
            if not (ROOT / rel).exists():
                continue
            # milestone2's legs drop the scene prefix — they ARE the
            # unprefixed originals, the same exception wired() carries.
            if mac_lane.leg_name(scene, lang) not in mac_leg_names:
                bad.append(
                    f'tools/lib/lanes/mac.py: scene "{scene}" has a '
                    f"{lang} guest but no leg runs it (wanted "
                    f'"{mac_lane.leg_name(scene, lang)}")')
    return bad


out = sweep_guests()
if out:
    for b in out:
        print(f"check-steps: {b}", file=sys.stderr)
    status = 1


# AND THE C FLOOR IS SWEPT LIKE EVERY OTHER LANGUAGE, but on its own
# terms. It cannot be a row in the sweep above: that sweep demands a
# mac leg for every scene whose guest file exists, and the C floor
# deliberately does not carry every scene on every lane — it is the
# explicit-tier demonstration, not a breadth guest.
#
# THE BINARY PATH IS THE LEG SIGNATURE, because the three runners
# spell a C leg three ways and the binary they execute is what all
# three share — the thing that cannot be present while the leg is
# dead.
def sweep_c_floor():
    RUNNERS = ("tools/linux/run-suites.sh",
               "tools/deploy-win.py", "tools/ios/run-sim.py",
               "tools/android/run-emulator.py")
    makefile = read_rel("guests/c/Makefile")
    m = re.search(r"^SCENES\s*:?=\s*(.+)$", makefile, re.M)
    if not m:
        print("check-steps: guests/c/Makefile has no SCENES variable",
              file=sys.stderr)
        return 1
    built = m.group(1).split()

    bad = []
    runs = {}   # scene -> the runners that execute its C binary
    # The mac lane's C legs are the lane MODULE's, imported: the stem
    # of every `c` leg in the queue. A queue with no C legs at all is
    # a moved table, not a shrunk floor.
    mac_c = sorted({mac_lane.guest_stem(scene)
                    for _n, scene, lang in mac_lane.legs()
                    if lang == "c"})
    if not mac_c:
        bad.append("tools/lib/lanes/mac.py: the mac queue carries no "
                   "C legs at all — this census read nothing and "
                   "would agree with anything")
    for name in mac_c:
        if name not in built:
            bad.append(f"tools/lib/lanes/mac.py: runs c-guests/{name}, "
                       f"which guests/c/Makefile never builds (SCENES "
                       f'has no "{name}")')
            continue
        runs.setdefault(name, []).append("tools/lib/lanes/mac.py")
    for runner in RUNNERS:
        text = read_rel(runner)
        for name in re.findall(r"c-guests/([A-Za-z0-9_]+)", text):
            # A leg pointing at a binary the Makefile never builds runs
            # nothing at all: `make` succeeds, the file is absent, and
            # the leg dies at exec time on whichever lane owns it.
            if name not in built:
                bad.append(f"{runner}: runs c-guests/{name}, which "
                           f"guests/c/Makefile never builds (SCENES "
                           f'has no "{name}")')
                continue
            runs.setdefault(name, []).append(runner)

    # 1. EVERY C GUEST THE FLOOR SHIPS IS RUN SOMEWHERE. This is the
    #    clause the gap was about: a leg that falls out of a runner
    #    leaves a guest that compiles, ships, and is executed by
    #    nobody — the exact shape that hid working OCaml and Haskell
    #    clipboard guests for a milestone.
    for scene in built:
        if scene not in runs:
            bad.append(f"guests/c/{scene}.c is built by "
                       f"guests/c/Makefile but no lane runs it (wanted "
                       f"a leg naming c-guests/{scene} in the mac lane "
                       f"module or one of: " + ", ".join(RUNNERS) + ")")

    # 2. A RUNNER THAT NAMES THE C SCENES IT BUILDS RUNS THEM: a build
    #    with no leg is a binary compiled for nothing. The mac lane's
    #    build list is the module's C_SCENES (what build_c passes to
    #    make); runners that build the whole floor (linux) declare
    #    nothing here and are covered by clause 1.
    for scene in mac_lane.C_SCENES:
        if scene not in mac_c:
            bad.append(f'tools/lib/lanes/mac.py: builds the C '
                       f'"{scene}" guest (C_SCENES) but queues no leg '
                       f"for it — wire the leg, or stop building it")
    for runner in RUNNERS:
        text = read_rel(runner)
        for at in (mm.end() for mm in
                   re.finditer(r"make\s+-C\s+guests/c\b", text)):
            # The logical line, continuations joined: the SCENES=
            # assignment and the make it belongs to are routinely
            # split across two.
            line = ""
            for raw in text[at:].splitlines():
                line += raw
                if not raw.rstrip().endswith("\\"):
                    break
            named = re.search(r'SCENES=(?:"([^"]*)"|(\S+))', line)
            if not named:
                continue
            for scene in (named.group(1) or named.group(2)).split():
                if f"c-guests/{scene}" not in text:
                    bad.append(f'{runner}: builds the C "{scene}" '
                               f"guest (SCENES={scene}) but runs no "
                               f"leg for it — wire the leg, or stop "
                               f"building it")
    for b in bad:
        print(f"check-steps: {b}", file=sys.stderr)
    return 1 if bad else 0


if sweep_c_floor():
    status = 1


# EVERY WINDOWS LEG NEEDS ITS LAUNCHER. deploy-win schedules
# C:\kaya\run_<leg>.cmd on the VM and those .cmd files are CHECKED IN
# under tools/guest. A leg whose launcher does not exist does not
# fail: schtasks starts nothing, no output appears, and the runner
# waits out its full 300s timeout before calling it a hang.
# NO LEG RUNS TWICE. deploy-win submits by name, and a name submitted
# twice runs the scene twice against the same output file — the second
# verdict silently replaces the first, and a duplicate looks exactly
# like a leg. Both clauses read the lane module's roster — the same
# list the runner iterates — so the prose-vs-call trap the old text
# roster carried is gone with the text.
def duplicate_legs(legs, path):
    counts = {}
    for n in legs:
        counts[n] = counts.get(n, 0) + 1
    return [f'{path}: leg "{n}" is submitted {c} times'
            for n, c in counts.items() if c > 1]


# The guard guards itself, both directions.
if not duplicate_legs(["nav_rust", "nav_rust"], "-"):
    selftest_fail("duplicate leg passed")
if duplicate_legs(["nav_rust", "nav_python"], "-"):
    selftest_fail("distinct legs rejected")

out = duplicate_legs(win_lane.legs(), "tools/lib/lanes/win.py")
if out:
    print("check-steps: the win lane module submits the same leg more "
          "than once — the second run overwrites the first's output "
          "file and buys nothing:", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


def launchers():
    failed = 0
    for leg in win_lane.legs():
        # The module roster covers the milestone2 bare legs too
        # (run_rust.cmd and kin), which the old text roster's
        # <scene>_<lang> shape never could.
        if not (ROOT / "tools" / "guest"
                / win_lane.launcher(leg)).is_file():
            print(f'check-steps: the win lane wires leg "{leg}" but '
                  f"tools/guest/{win_lane.launcher(leg)} does not "
                  f"exist — that leg would wait out its whole timeout "
                  f"in silence", file=sys.stderr)
            failed = 1
    return failed


if launchers():
    status = 1


# EVERY JS LAUNCHER HAS ONE SHAPE (2026-09-01): CRLF (cmd.exe reads a
# lone LF as part of the command, docs/traps.md), the pinned node on
# PATH by the version deploy-win.py records, KAYA_LIB naming the shipped
# dll, KAYA_SELFTEST naming the scene (1 for the bare milestone2 leg),
# the flat guest (split for listdetail) run into the leg's own out file.
# Generated once and checked in; this is what keeps a hand edit from
# drifting one of forty near-identical files.
def js_launchers(files, node_version):
    bad = []
    if not files:
        bad.append("tools/guest: no JS launcher read — the census "
                   "compared nothing")
    for name, raw in files:
        leg = name[len("run_"):-len(".cmd")]
        scene, _lang = win_lane.scene_lang(leg)
        if b"\r\n" not in raw or b"\n" in raw.replace(b"\r\n", b""):
            bad.append(f"tools/guest/{name}: not CRLF throughout — "
                       f"cmd.exe reads a lone LF as part of the command")
        text = raw.decode("ascii", "replace")
        guest = ("milestone2" if leg == "js"
                 else "split" if scene == "listdetail" else scene)
        selftest = "1" if leg == "js" else scene
        for want in (
                "set KAYA_LIB=C:\\kaya\\kaya.dll",
                f"node-v{node_version}-win-arm64",
                f"set KAYA_SELFTEST={selftest}",
                f"node C:\\kaya\\{guest}.ts > C:\\kaya\\out_{leg}.txt 2>&1",
                f"echo EXIT=%ERRORLEVEL% >> C:\\kaya\\out_{leg}.txt"):
            if want not in text:
                bad.append(f"tools/guest/{name}: lacks `{want}`")
    return bad


_deploy_text = read_rel("tools/deploy-win.py")
_node_version = re.search(r'^NODE_VERSION = "([0-9.]+)"$', _deploy_text, re.M)
if _node_version is None:
    print("check-steps: tools/deploy-win.py records no NODE_VERSION — the "
          "JS launcher clause cannot know which node the lane pins",
          file=sys.stderr)
    status = 1
    _node_version_s = "0.0.0"
else:
    _node_version_s = _node_version.group(1)
_ok = ("@echo off\r\ncd /d C:\\kaya\r\nset PATH=C:\\kaya;C:\\kaya\\node24\\node-v"
       + _node_version_s + "-win-arm64;%PATH%\r\nset KAYA_LIB=C:\\kaya\\kaya.dll\r\n"
       "set KAYA_SELFTEST=todos\r\nnode C:\\kaya\\todos.ts > C:\\kaya\\out_todos_js.txt 2>&1\r\n"
       "echo EXIT=%ERRORLEVEL% >> C:\\kaya\\out_todos_js.txt\r\n").encode()
if js_launchers([("run_todos_js.cmd", _ok)], _node_version_s):
    selftest_fail("a well-formed JS launcher was refused")
if not js_launchers([("run_todos_js.cmd", _ok.replace(b"\r\n", b"\n"))], _node_version_s):
    selftest_fail("an LF-ended JS launcher passed")
if not js_launchers([("run_todos_js.cmd",
                      _ok.replace(b"set KAYA_LIB=C:\\kaya\\kaya.dll\r\n", b""))],
                    _node_version_s):
    selftest_fail("a JS launcher with no KAYA_LIB passed")
if not js_launchers([("run_todos_js.cmd",
                      _ok.replace(b"node-v" + _node_version_s.encode(),
                                  b"node-v0.0.1"))], _node_version_s):
    selftest_fail("a JS launcher on a stale node passed")
if not js_launchers([("run_todos_js.cmd", _ok.replace(b"todos.ts", b"feed.ts"))], _node_version_s):
    selftest_fail("a JS launcher running another scene's guest passed")
if not js_launchers([], _node_version_s):
    selftest_fail("an EMPTY JS launcher census passed")
out = js_launchers(
    [(p.name, p.read_bytes()) for p in sorted((ROOT / "tools" / "guest").glob("run_*.cmd"))
     if p.name.endswith("_js.cmd") or p.name == "run_js.cmd"],
    _node_version_s)
if out:
    print("check-steps: a JS launcher strays from the one shape the lane "
          "runs them in:", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


# The staged WinUI ruling (docs/traps.md), covering THREE scene
# families that share one cause: the leg needs the DESKTOP to itself.
#
#   menus_*      shortcut injection is OS-global — the harness puts
#                the real chord on the system input queue.
#   filedialog_* a file dialog is modal, must hold the FOREGROUND to
#                be driven, and the harness finds it by searching the
#                desktop. Two up at once means BOTH legs fail.
#   save_*       the same OS-global modal chrome: `live_dialog` walks
#                the DESKTOP for a visible `#32770` and takes the
#                first, so a picker up beside it eats the typing.
#
# So deploy-win must run each of these ALONE, between drains. The lane
# module's ORDER is a list of BLOCKS with the pool draining between
# them, so "alone between drains" IS "in a block of its own" — read
# structurally, and a parallelizing refactor cannot re-pool a leg
# without moving it into a wider block this refuses. `undo_` joined
# the family here with the conversion: the old shell body's undo block
# carried a comment saying the text pattern must grow an undo arm or a
# refactor could re-pool it with nothing to say so, and the pattern
# never did.
def menu_serial(order, path):
    bad = []
    seen = 0
    for block in order:
        for leg in block:
            if not re.match(r"(menus|filedialog|save|undo)_", leg):
                continue
            seen += 1
            if list(block) != [leg]:
                bad.append(f'{path}: leg "{leg}" shares a block with '
                           f"{len(block) - 1} other leg(s) and lacks "
                           f"the drain/run/drain barrier")
    if seen == 0:
        bad.append(f"{path}: no menus_*/filedialog_*/save_*/undo_* "
                   f"leg found (all four scenes must stay wired)")
    return bad


# The guard guards itself: a pooled leg of each family must fail.
if not menu_serial([["layout_java", "menus_rust"]], "-"):
    selftest_fail("pooled menus leg passed")
if not menu_serial([["layout_java", "filedialog_python"]], "-"):
    selftest_fail("pooled filedialog leg passed")
if not menu_serial([["layout_java", "save_rust"]], "-"):
    selftest_fail("pooled save leg passed")
if not menu_serial([["layout_java", "undo_rust"]], "-"):
    selftest_fail("pooled undo leg passed")

out = menu_serial(win_lane.ORDER, "tools/lib/lanes/win.py")
if out:
    print("check-steps: the win lane's menus/filedialog/save/undo legs "
          "must run in blocks of their own (docs/traps.md — each needs "
          "the desktop to itself):", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


# THE CLIPBOARD LEGS ARE MUTUALLY EXCLUSIVE ON EVERY LANE
# (docs/clipboard-plan.md §0d): one system clipboard per session, and
# concurrent legs are processes assigning one variable. On wayland the
# serial primer's F24 tap additionally needs the pool EMPTY (§5b
# finding 3). Pinned structurally: every clipboard leg must have
# `drain` as its nearest significant neighbor on BOTH sides.
# Continuation lines are joined first, because a leg's command usually
# wraps.
# The family NAME is a parameter because this helper serves two
# families with two different reasons, and a barrier gate whose
# "nothing matched" message names the wrong scene cannot have measured
# what it prints.
def family_serial(text, leg_pattern, barrier, family, path):
    raw = text.splitlines()
    lines = []
    buf = ""
    for line in raw:
        s = line.strip()
        if buf:
            s = buf + " " + s
            buf = ""
        if s.endswith("\\"):
            buf = s[:-1].rstrip()
            continue
        lines.append(s)

    def significant(seq):
        return [line for line in seq
                if line and not line.startswith("#")]

    bad = []
    seen = 0
    for n, line in enumerate(lines):
        if not re.match(leg_pattern, line):
            continue
        seen += 1
        before = significant(lines[:n])
        after = significant(lines[n + 1:])
        if not before or before[-1] != barrier or not after \
                or after[0] != barrier:
            bad.append(f"{path}:{n + 1}: {line[:60]} lacks the "
                       f"{barrier}/run/{barrier} barrier")
    if seen == 0:
        bad.append(f"{path}: no {family} leg found (the scene must "
                   f"stay wired)")
    return bad


# Each runner spells its pool differently, so the rule is checked in
# each runner's own vocabulary; the win lane's vocabulary is the
# module's block structure, one clause down.
MAC_LEG = r"run .*clipboard-[a-z]"

# The guard guards itself: two clipboard legs sharing the pool must
# fail...
if not family_serial("drain\nrun clipboard-rust-swiftui env X\n"
                     "run clipboard-python-swiftui env X\ndrain\n",
                     MAC_LEG, "drain", "clipboard", "-"):
    selftest_fail("pooled clipboard legs passed")
# ...a clipboard leg entering a pool that still holds another scene's
# leg (on wayland the primer would tap that leg's window)...
if not family_serial("run layout-java env X\nrun clipboard-rust env "
                     "X\ndrain\n", MAC_LEG, "drain", "clipboard", "-"):
    selftest_fail("undrained-before clipboard leg passed")

# THE LINUX ALONE-FAMILIES, one clause each: clipboard (one system
# clipboard per session), and undo and ranges (real keystrokes through
# a virtual keyboard whose seat is EXCLUSIVE across the pooled legs —
# run-suites.sh's own comment at the undo block). The ranges pair was
# the measured miss: the ninth binding's leg was inserted inside the
# python leg's bracket, both wayland legs typed into each other's
# window, and only clipboard was held here (2026-09-01,
# docs/measurements/js-binding-2026-09-01.md).
# (The clipboard rule is docs/clipboard-plan.md §0d; cited here rather
# than in the message, since a path in a string literal reads as an
# input to check-keyed.)
LINUX_ALONE = (
    ("clipboard", MAC_LEG, "one system clipboard per session"),
    ("undo", r"run .*undo-[a-z]", "the type verb's virtual keyboard seat "
                                  "is exclusive across the pool"),
    ("ranges", r"run .*ranges-[a-z]", "the undo rule: the type verb's "
                                      "seat is exclusive across the pool"),
)
# The guard guards itself against the measured shape: a second
# language's leg sharing the first's bracket.
if not family_serial("drain\nrun ranges-python env X\nrun ranges-js env "
                     "X\ndrain\n", r"run .*ranges-[a-z]", "drain",
                     "ranges", "-"):
    selftest_fail("a ranges leg inside another's bracket passed")
for family, leg, why in LINUX_ALONE:
    runner = "tools/linux/run-suites.sh"
    out = family_serial(read_rel(runner), leg, "drain", family, runner)
    if out:
        print(f"check-steps: {runner} {family} legs must run ALONE "
              f"between drains ({why}):", file=sys.stderr)
        print("\n".join(out), file=sys.stderr)
        status = 1


# The mac lane's serial families, in the module's own vocabulary since
# the runner conversion: a block of its own per leg, read from the
# same ORDER the runner walks (win_clipboard_serial's shape).
def mac_family_serial(order_blocks, family, path):
    bad = []
    seen = 0
    prefix = f"{family}-"
    for block in order_blocks:
        for leg in block:
            if not leg.startswith(prefix):
                continue
            seen += 1
            if list(block) != [leg]:
                bad.append(f'{path}: leg "{leg}" shares a block with '
                           f"{len(block) - 1} other leg(s)")
    if seen == 0:
        bad.append(f"{path}: no {family} leg found (the scene must "
                   f"stay wired)")
    return bad


# The guard guards itself, on the mac spelling and the REASON.
if not mac_family_serial(
        [["clipboard-rust-swiftui", "clipboard-python-swiftui"]],
        "clipboard", "-"):
    selftest_fail("pooled mac clipboard legs passed")
if not mac_family_serial([["nav-rust-swiftui"]], "clipboard", "-"):
    selftest_fail("a mac roster with no clipboard leg passed")

out = mac_family_serial(mac_lane.blocks(), "clipboard",
                        "tools/lib/lanes/mac.py")
if out:
    print("check-steps: the mac lane's clipboard legs must run in "
          "blocks of their own (docs/clipboard-plan.md §0d — one "
          "system clipboard per session):", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


# The win lane's clipboard rule, in the module's own vocabulary: a
# block of its own per leg. The same structural read as menu_serial,
# with §0d's reason rather than the desktop's.
def win_clipboard_serial(order, path):
    bad = []
    seen = 0
    for block in order:
        for leg in block:
            if not leg.startswith("clipboard_"):
                continue
            seen += 1
            if list(block) != [leg]:
                bad.append(f'{path}: leg "{leg}" shares a block with '
                           f"{len(block) - 1} other leg(s)")
    if seen == 0:
        bad.append(f"{path}: no clipboard leg found (the scene must "
                   f"stay wired)")
    return bad


if not win_clipboard_serial([["clipboard_rust", "clipboard_python"]], "-"):
    selftest_fail("pooled win clipboard legs passed")
if not win_clipboard_serial([["nav_rust"]], "-"):
    selftest_fail("a win roster with no clipboard leg passed")

out = win_clipboard_serial(win_lane.ORDER, "tools/lib/lanes/win.py")
if out:
    print("check-steps: the win lane's clipboard legs must run in "
          "blocks of their own (docs/clipboard-plan.md §0d — one "
          "system clipboard per session):", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

# THE SAVE LEGS ARE MUTUALLY EXCLUSIVE ON THE MAC LANE, and the shared
# thing is the PANEL rather than the scene: macOS remembers a save
# panel's last directory as a USER PREFERENCE shared by every process,
# so guests opening panels in one pool trample it (measured 2026-08-10
# — a leg asserting its own kaya-save-<pid> directory was shown a
# SIBLING's, and serialising them raised the mac ceiling to 560s).
#
# THE OTHER TWO DESKTOP RUNNERS ARE NOT IN THIS LOOP, and the omission
# is the rule rather than a gap:
#
#   deploy-win  IS covered one clause up: its save legs ride the
#               menus/filedialog barrier, because there the shared
#               thing is the desktop's one modal `#32770`.
#   linux       is DELIBERATELY pooled: GTK's save panel is driven
#               over the PER-LEG accessibility bus, remembers no
#               cross-process directory, and each leg's files live
#               under $TMPDIR/kaya-save-<pid>. A barrier there could
#               not fail for the reason it exists (CLAUDE.md
#               invariant 4).
# The guard guards itself: two save legs sharing a block must fail...
if not mac_family_serial(
        [["save-rust-swiftui", "save-python-swiftui"]], "save", "-"):
    selftest_fail("pooled save legs passed")
# ...a save leg sharing a block with another scene's leg, which is the
# same trample from the other side: the sibling's panel is what wrote
# the preference this leg is about to read...
if not mac_family_serial(
        [["layout-java-swiftui", "save-rust-swiftui"]], "save", "-"):
    selftest_fail("undrained-before save leg passed")
# ...and a roster with no save leg at all must fail.
if not mac_family_serial([["nav-rust-swiftui"]], "save", "-"):
    selftest_fail("a mac roster with no save leg passed")

out = mac_family_serial(mac_lane.blocks(), "save",
                        "tools/lib/lanes/mac.py")
if out:
    print("check-steps: the mac lane's save legs must run in blocks "
          "of their own (docs/save-plan.md, measured 2026-08-10 — "
          "macOS shares a save panel's last directory as a user "
          "preference across every process, so a pooled leg is shown "
          "a sibling's):", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

# THE ANDROID LANE IS NOT IN THAT LOOP, AND THE OMISSION IS THE RULE.
# §0d requires that a leg read the clipboard THAT LEG WROTE; this
# lane's pool is separate emulators, each with its own ClipboardService
# and the host bridge severed both ways (§7 finding 4), so a session
# here is a DEVICE and run_apk's slot lock IS this runner's exclusion.
#
# A drain bracket on top would exclude nothing, and a gate satisfiable
# without exercising the real thing is a bug in the gate (invariant
# 4). So this checks the two things that CAN go wrong: a clipboard leg
# that stops riding the slot-locked pool (the tablet is the live
# temptation — one device, no lock), and a worker that stops claiming
# a device. The roster is the lane MODULE's since the runner
# conversion; the pool mechanics are read out of the python body,
# exactly the ios clause's shape below.
def clipboard_device(text, path, mod):
    bad = []
    clip_legs = [leg for leg in mod.legs()
                 if mod.scene_of(leg) == "clipboard"]
    if not clip_legs:
        bad.append(f"{path}: no clipboard leg found (the scene must "
                   f"stay wired)")
    for leg in clip_legs:
        if mod.FLAGS.get(leg, {}).get("tablet"):
            bad.append(f"{path}: {leg} rides the tablet — the one "
                       f"device with no slot lock, so two clipboard "
                       f"legs on it would share that device clipboard; "
                       f"only a pool leg claims an emulator for the "
                       f"whole leg")
    worker = py_function_body(text, "_leg_worker", path, bad)
    claim = py_function_body(text, "_claim_device", path, bad)
    if worker and ("_claim_device()" not in worker
                   or "_release_device(slot)" not in worker):
        bad.append(f"{path}: _leg_worker no longer claims and releases "
                   f"a device slot, so a leg no longer holds its "
                   f"emulator alone — on this lane that lock IS the "
                   f"clipboard exclusion (docs/clipboard-plan.md §0d, "
                   f"§7 finding 4)")
    if claim and "_dev_slots.pop" not in claim:
        bad.append(f"{path}: _claim_device no longer takes a slot from "
                   f"the device pool, so a leg no longer holds its "
                   f"emulator alone — on this lane that lock IS the "
                   f"clipboard exclusion (docs/clipboard-plan.md §0d, "
                   f"§7 finding 4)")
    return bad


ANDROID_RUNNER_TEXT = read_rel("tools/android/run-emulator.py")
ANDROID_LANE_TEXT = read_rel("tools/lib/lanes/android.py")


# The guard guards itself in the ANDROID spelling, on the REAL runner
# and lane module, and on the REASON rather than the exit code: a
# negative test whose failure comes from somewhere else proves nothing
# about the clause it covers. Counts printed; an unchanged copy is a
# failed test. The executions sit with the iOS negatives below, after
# load_lane_copy is defined.
def android_device_selftest(sample, want, label, mod):
    out = clipboard_device(sample, "-", mod)
    if not out:
        selftest_fail(f"{label} passed")
    if not any(want in b for b in out):
        selftest_fail(f"{label} failed for another reason: "
                      + "\n".join(out))


def android_applied(hits, label, want=1):
    print(f"check-steps: android self-test {label} applied {hits} "
          f"substitution(s)")
    if hits != want:
        selftest_fail(f"{label} applied {hits} times, want {want} — "
                      f"an unchanged copy cannot prove the rule fires")


# THE iOS LANE IS THE ANDROID SHAPE, FOR THE ANDROID REASON: two
# simulators held two different clips at once while the host's stayed
# untouched (docs/clipboard-plan.md §8 finding 5). A session is a
# DEVICE, and the slot queue_leg claims IS this lane's exclusion.
#
# A clipboard leg must claim a simulator and ride run_swiftui_on: the
# claim holds the device, run_swiftui_on starts the host-side watcher
# that answers clipboard_seed and expect_clipboard — the guest cannot
# spawn a child process here. It must not ride kaya-sim-pad, ONE
# lockless device. The runner is python since the conversion
# (tools/ios/run-sim.py) and its rosters are the lane module's
# (tools/lib/lanes/ios.py), so membership is IMPORTED and the pool
# mechanics are read out of the python body.
def clipboard_ios(text, path, mod):
    bad = []

    # Which suites carry the clipboard scene — the module's lists, the
    # same tables the runner derives its legs from.
    suites_with = []
    for label, scenes in (
            ("swift", [e.split(":")[0] for e in mod.SWIFT_ENTRIES]),
            ("go", mod.GO_SCENES),
            ("python", mod.PYTHON_SCENES),
            ("rust-swiftui", mod.RUST_SCENES)):
        if "clipboard" in scenes:
            suites_with.append(label)
    if not suites_with:
        bad.append(f"{path}: no clipboard leg found (the scene must "
                   f"stay wired)")

    # THE SEED HOLDER RETIRES ITSELF (docs/traps.md, 2026-09-01): a kill
    # reaches its timeout wrapper alone and a group kill wedges the
    # pasteboard daemon, so the writer polls a RELEASE FILE the runner
    # touches, the runner waits for it to leave, and the verdict is
    # gated on a census of this run's survivors. Measured both ways by
    # hand: the census saw all four processes of a live holder, and
    # half a second after the release file appeared it saw none.
    seed = " ".join(py_function_body(text, "clip_seed", path, bad).split())
    if '"hold", str(release)]' not in seed \
            or "clip_release_holder(udid)" not in seed:
        bad.append(f"{path}: clip_seed does not release the previous "
                   f"holder and hand the new one its release file")
    release = py_function_body(text, "clip_release_holder", path, bad)
    if "release.touch()" not in release \
            or "holder.wait(timeout=" not in release \
            or "_holders_late.append" not in release:
        bad.append(f"{path}: clip_release_holder does not touch the "
                   f"release file, wait for the holder to leave and "
                   f"count one that does not")
    census = " ".join(py_function_body(text, "clip_holder_census", path,
                                       bad).split())
    if 'f"hold {LEGS_DIR}/release-"' not in census \
            or "return not late" not in census:
        bad.append(f"{path}: clip_holder_census does not count this "
                   f"run's holders by their release directory and "
                   f"refuse on a late one")
    if re.search(r"(?m)^if not clip_holder_census\(\):\n    status = 1\n",
                 text) is None:
        bad.append(f"{path}: the seed-holder census does not gate the "
                   f"lane's verdict")
    if re.search(r"holder\.kill\(\)|killpg\(", text):
        bad.append(f"{path}: a seed holder is killed rather than "
                   f"released — a kill reaches the timeout wrapper "
                   f"alone, and a group kill wedges the pasteboard "
                   f"daemon (docs/traps.md)")

    # NOT ON THE PAD: kaya-sim-pad is a single LOCKLESS device, so legs
    # on it would share one pasteboard; the phone pool slot lock IS
    # this lane's clipboard exclusion (§8 finding 5).
    if "clipboard" in mod.PAD_EXTRAS:
        bad.append(f"{path}: a clipboard leg on the iPad — kaya-sim-pad "
                   f"is a single LOCKLESS device, so legs on it would "
                   f"share one pasteboard; the phone pool slot lock IS "
                   f"this lane's clipboard exclusion "
                   f"(docs/clipboard-plan.md §8 finding 5)")

    # ...and the ONLY route to the pad is the PAD_EXTRAS membership
    # test, so the module clause above is the whole story: exactly one
    # pad=True queue site, guarded by that membership.
    pad_sites = [n for n, line in enumerate(text.splitlines(), 1)
                 if "pad=True)" in line]
    if len(pad_sites) != 1:
        bad.append(f"{path}: {len(pad_sites)} pad=True queue sites — "
                   f"one guarded site is the rule, and zero means the "
                   f"pad legs are gone")
    else:
        lines = text.splitlines()
        window = "\n".join(lines[max(0, pad_sites[0] - 10):pad_sites[0]])
        if "if scene in lane.PAD_EXTRAS:" not in window:
            bad.append(f"{path}:{pad_sites[0]}: the pad queue is not "
                       f"guarded by PAD_EXTRAS membership — any scene "
                       f"could ride the lockless pad")

    # THE SLOT LOCK: a leg holds its simulator alone for its whole
    # duration — the claim comes from the device pool and is released
    # after the leg, and the worker runs the leg through
    # run_swiftui_on, the only place the host-side bridge starts.
    worker = py_function_body(text, "_leg_worker", path, bad)
    claim = py_function_body(text, "_claim_device", path, bad)
    if worker:
        flat = " ".join(worker.split())
        if ("_claim_device()" not in worker
                or "_release_device(slot)" not in worker):
            bad.append(f"{path}: _leg_worker no longer claims and "
                       f"releases a device slot, so a leg no longer "
                       f"holds its simulator alone — on this lane that "
                       f"lock IS the clipboard exclusion "
                       f"(docs/clipboard-plan.md §8 finding 5)")
        if "run_swiftui_on(udid, slot, *args, log=log, **kwargs)" \
                not in flat:
            bad.append(f"{path}: _leg_worker no longer runs the leg "
                       f"through run_swiftui_on — the host-side "
                       f"seed/read bridge is started there and nowhere "
                       f"else, and iOS cannot answer either verb in "
                       f"the guest process")
    if claim and "_dev_slots.pop" not in claim:
        bad.append(f"{path}: _claim_device no longer takes a slot from "
                   f"the device pool, so a leg no longer holds its "
                   f"simulator alone — on this lane that lock IS the "
                   f"clipboard exclusion "
                   f"(docs/clipboard-plan.md §8 finding 5)")

    # AND THE BOARD MUST BELONG TO THE DEVICE BEFORE ANY LEG RUNS:
    # Simulator.app relays the macOS pasteboard into and out of every
    # booted simulator while Automatically Sync Pasteboard is on, which
    # is the default (§8 finding 7). The runner MEASURES the isolation
    # inside prep_join, and queue_leg joins the preparation before it
    # queues anything.
    join_body = py_function_body(text, "prep_join", path, bad)
    if join_body and "clip_relay_check(UDIDS[0], PAD_UDID)" \
            not in join_body:
        bad.append(f"{path}: nothing measures the clipboard isolation "
                   f"— the pasteboard of a booted simulator belongs to "
                   f"Simulator.app too whenever it is running, and the "
                   f"legs then share one board with the mac lane "
                   f"(docs/clipboard-plan.md §8 finding 7). Call "
                   f"clip_relay_check in prep_join")
    queue_body = py_function_body(text, "queue_leg", path, bad)
    if queue_body:
        at_join = queue_body.find("prep_join()")
        at_thread = queue_body.find("threading.Thread")
        if at_join < 0 or (at_thread >= 0 and at_join > at_thread):
            bad.append(f"{path}: queue_leg queues a leg without joining "
                       f"the device preparation first — the isolation "
                       f"is then measured AFTER the first leg, and a "
                       f"lane that dies at leg 40 teaches nothing a "
                       f"lane that dies in five seconds does not")

    # NO LIVE LINE TOUCHES A HOST OR SHARED PASTEBOARD PATH: the
    # ratified shape is a spawned on-device write (tools/ios/clipctl),
    # so the pasteboard tools may appear here only in comments
    # explaining exactly this (§8 finding 6).
    for n, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if s.startswith("#"):
            continue
        if re.search(r"\bpbcopy\b|\bpbpaste\b|\bpbsync\b|"
                     r"set the clipboard", s):
            bad.append(f"{path}:{n}: a live line touches a pasteboard "
                       f"tool (`{s[:60]}`) — the clipboard seed/read "
                       f"is a spawned on-device process precisely so "
                       f"this lane cannot race the mac lane legs or "
                       f"its own delivery window "
                       f"(docs/clipboard-plan.md §8 finding 6)")
    return bad


def py_function_body(text, name, path, bad):
    """One python function's body, # comments stripped — the shell
    body reader's successor. An absent function is a finding, never a
    silent skip."""
    match = re.search(
        rf"(?ms)^def {re.escape(name)}\(.*?(?=^def |^class |^[A-Za-z_]"
        rf"[A-Za-z0-9_]* = |\Z)", text)
    if match is None:
        bad.append(f"{path}: no {name}() is where the iOS admission "
                   f"check looks")
        return ""
    return "\n".join(line for line in match.group(0).splitlines()
                     if not line.lstrip().startswith("#"))


# THE PICKER STACK MUST CLEAN, AIM AND EXPORT before any leg runs. A
# live FileProvider pid does not prove its LocalStorage index can
# materialize an export (docs/traps.md), so this checks the per-phone
# admission wall and the tiny app that supplies its result — the
# python spellings of the same walls the shell body carried.
def picker_ios(text, path, probe_text, probe_path):
    bad = []

    def fn(name):
        return py_function_body(text, name, path, bad)

    prepare = fn("picker_prepare")
    cleanup = fn("picker_cleanup")
    installed = fn("kaya_installed_apps")
    reseed = fn("picker_reseed")
    export = fn("picker_export_probe")
    prep_join = fn("prep_join")

    # LocalStorage admission runs once per phone pool device, with a
    # per-device verdict the join reads.
    if ("for _udid in UDIDS:" not in text
            or "_prep_results[u] = picker_prepare(u)" not in text):
        bad.append(f"{path}: LocalStorage admission is not prepared "
                   f"once per phone pool UDID with a per-device "
                   f"verdict")

    # Exactly two warmed export attempts around one measured-failure
    # reseed, cleanup first, no open-ended retry. Each attempt may run
    # its probe ONCE MORE, on the slow-flow code (76) alone: under
    # matrix load the flow that did not finish reads like the stale
    # export, and a reseed on that reading erased a healthy device
    # twice (2026-09-01), so the second read is of the device the first
    # left warm — never a loop, never on any other code.
    order = []
    for token in ("picker_cleanup(udid)", "picker_warm(udid)",
                  "picker_export_probe(udid)", "picker_reseed(udid)"):
        order.append([m.start() for m in
                      re.finditer(re.escape(token), prepare)])
    cleanup_calls, warm_calls, probe_calls, reseed_calls = order
    if len(cleanup_calls) != 1 or not warm_calls \
            or cleanup_calls[0] > warm_calls[0]:
        bad.append(f"{path}: picker_prepare does not clean every "
                   f"prior-run kaya app before warming and probing "
                   f"LocalStorage")
    slow_guarded = (
        len(probe_calls) == 4
        and prepare[probe_calls[0]:probe_calls[1]].count("if rc == 76:") == 1
        and prepare[probe_calls[2]:probe_calls[3]].count("if rc == 76:") == 1
        and prepare.count("if rc == 76:") == 2)
    if not slow_guarded or len(warm_calls) != 2 \
            or len(reseed_calls) != 1 \
            or not (warm_calls[0] < probe_calls[0] < probe_calls[1]
                    < reseed_calls[0] < warm_calls[1] < probe_calls[2]
                    < probe_calls[3]) \
            or re.search(r"(?m)^\s*(for|while)\b", prepare) \
            or "if rc != 75:" not in prepare:
        bad.append(f"{path}: picker_prepare must spell exactly two "
                   f"warmed export attempts around one "
                   f"measured-failure reseed, each re-run at most once "
                   f"on the slow-flow code alone, with no open-ended "
                   f"retry")

    # The prior-run app census is scoped exactly to the dev.kaya.
    # prefix, and its emitter is live.
    flat_installed = " ".join(installed.split())
    installed_parts = [
        '"simctl", "listapps"',
        '"plutil", "-convert", "json"',
        "json.loads",
        "isinstance(apps, dict)",
        "startswith(KAYA_BUNDLE_PREFIX)",
    ]
    if re.search(r'(?m)^KAYA_BUNDLE_PREFIX = "dev\.kaya\."$', text) \
            is None \
            or not all(part in flat_installed
                       for part in installed_parts):
        bad.append(f"{path}: prior-run app census is not scoped "
                   f"exactly to the dev.kaya. bundle prefix")

    # picker_cleanup: bounded per-device uninstalls, both censuses, the
    # refusal on survivors — and NOTHING destructive.
    flat_cleanup = " ".join(cleanup.split())
    if (cleanup.count("kaya_installed_apps(udid)") != 2
            or 'startswith("dev.kaya.")' not in cleanup
            or '"timeout", "60", "xcrun", "simctl", "uninstall", udid, '
               'bundle]' not in flat_cleanup
            or "if remaining:" not in cleanup
            or re.search(r'"(?:delete|erase|shutdown|boot|bootstatus)"',
                         cleanup)
            or re.search(r"\b(?:rmtree|unlink|remove)\b", cleanup)):
        bad.append(f"{path}: picker_cleanup does not use bounded "
                   f"simctl uninstalls and verify that no prior-run "
                   f"kaya app remains")

    # picker_reseed: a bounded shutdown/erase/boot of exactly $udid.
    flat_reseed = " ".join(reseed.split())
    reseed_steps = ['"shutdown", udid', '"erase", udid', '"boot", udid',
                    '"bootstatus", udid']
    positions = [flat_reseed.find(step) for step in reseed_steps]
    if any(at < 0 for at in positions) \
            or positions != sorted(positions) \
            or re.search(r'"(?:all|booted)"', reseed):
        bad.append(f"{path}: picker_reseed is not a bounded "
                   f"shutdown/erase/boot of exactly $udid")

    # picker_export_probe drives and classifies the REAL export result
    # before admitting a device.
    flat_export = " ".join(export.split())
    export_parts = [
        '"install", udid, EXPORT_PROBE_APP]',
        '"savename", probe_name]',
        '"savepress"]',
        'if result == "ok": return 0',
        '"FP -1005" in haystack',
        '"Index out of sync" in haystack',
        'or "didPickDocumentURLs called with nil or 0 URLS" in '
        'haystack',
        "return 75",
    ]
    if not all(part in flat_export for part in export_parts) \
            or flat_export.find('"savename", probe_name]') \
            > flat_export.find('"savepress"]'):
        bad.append(f"{path}: picker_export_probe no longer drives and "
                   f"classifies the real export result before "
                   f"admitting a device")

    probe_parts = [
        "UIDocumentPickerViewController(forExporting: [source], "
        "asCopy: true)",
        "guard let destination = urls.first else",
        "let copied = try Data(contentsOf: destination)",
        "guard copied == payload else",
        "func documentPickerWasCancelled",
        'publish("empty documentPickerWasCancelled")',
    ]
    if not all(part in probe_text for part in probe_parts):
        bad.append(f"{probe_path}: export probe no longer requires a "
                   f"nonempty callback and an exact byte readback, "
                   f"with cancellation kept red")

    # prep_join measures clipboard isolation only after every device's
    # recovery has finished and its verdict has been checked.
    join_steps = [
        prep_join.find("t.join()"),
        prep_join.find("_prep_results.get"),
        prep_join.find("clip_relay_check(UDIDS[0], PAD_UDID)"),
    ]
    if any(at < 0 for at in join_steps) \
            or join_steps != sorted(join_steps):
        bad.append(f"{path}: prep_join measures clipboard isolation "
                   f"before device recovery has finished and its "
                   f"verdicts have been checked")

    # Recording cannot start before a possible erase/reboot recovery
    # has been retired.
    record_wall = ('if os.environ.get("KAYA_RECORD"):\n'
                   "    prep_join()\n"
                   "rec_suite_start()")
    if record_wall not in text:
        bad.append(f"{path}: recording can start before picker "
                   f"recovery retires its erase/reboot")
    return bad


# THE GUARD GUARDS ITSELF, on the REAL runner and the REAL lane module
# (docs/traps.md: the wayland seat guard passed VACUOUSLY TWICE). Each
# perturbation prints its substitution count and the copy is refused
# if it did not apply, and each refusal is checked for its REASON.
RUN_SIM = read_rel("tools/ios/run-sim.py")
IOS_LANE_TEXT = read_rel("tools/lib/lanes/ios.py")
EXPORT_PROBE = read_rel("tools/ios/exportprobe/main.swift")


def ios_applied(hits, label, want=1):
    print(f"check-steps: iOS self-test {label} applied {hits} "
          f"substitution(s)")
    if hits != want:
        selftest_fail(f"{label} applied {hits} times, want {want} — "
                      f"an unchanged copy cannot prove the rule fires")


def load_lane_copy(module_text):
    """A doctored lane module, imported from scratch under a throwaway
    name — the negatives must perturb what the census actually reads."""
    import importlib.util
    with tempfile.TemporaryDirectory() as td:
        p = pathlib.Path(td) / "doctored_lane.py"
        p.write_text(module_text, encoding="utf-8")
        spec = importlib.util.spec_from_file_location("kaya_ios_shadow",
                                                      p)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod


def ios_selftest(doctored, want, label, mod=ios_lane):
    out = clipboard_ios(doctored, "-", mod)
    if not out:
        selftest_fail(f"{label} passed")
    if not any(want in b for b in out):
        selftest_fail(f"{label} failed for another reason: "
                      + "\n".join(out))


def picker_selftest(runner_text, want, label,
                    probe_text=EXPORT_PROBE):
    out = picker_ios(runner_text, "-", probe_text, "-")
    if not out:
        selftest_fail(f"{label} passed")
    if not any(want in b for b in out):
        selftest_fail(f"{label} failed for another reason: "
                      + "\n".join(out))


# A clipboard leg moved onto the lockless pad must fail...
doc, hits = sub_count(r"(?m)^PAD_EXTRAS = \{\n",
                      'PAD_EXTRAS = {\n    "clipboard": "",\n',
                      IOS_LANE_TEXT)
ios_applied(hits, "the pad-membership perturbation")
ios_selftest(RUN_SIM, "on the iPad", "a clipboard leg on the pad",
             mod=load_lane_copy(doc))

# ...a pad queue no longer guarded by the module's membership must
# fail...
doc, hits = sub_count(r"if scene in lane\.PAD_EXTRAS:", "if True:",
                      RUN_SIM)
ios_applied(hits, "the unguarded-pad perturbation")
ios_selftest(doc, "not guarded by PAD_EXTRAS",
             "a pad queue any scene could ride")

# ...a worker that stopped claiming a device must fail...
doc, hits = sub_count(r"_dev_slots\.pop\(0\)", "0", RUN_SIM)
ios_applied(hits, "the slot-lock perturbation")
ios_selftest(doc, "no longer takes a slot", "an unlocked device claim")

# ...a worker that stopped running the leg through run_swiftui_on must
# fail...
doc, hits = sub_count(
    r"ok = run_swiftui_on\(udid, slot, \*args, log=log, \*\*kwargs\)",
    "ok = True", RUN_SIM)
ios_applied(hits, "the bridge-bypass perturbation")
ios_selftest(doc, "no longer runs the leg through run_swiftui_on",
             "a leg that bypasses the host-side bridge")

# ...an unwired scene must fail, which takes EVERY suite's membership
# away. The count is the number of suite lists carrying clipboard — 3
# today — STATED rather than derived, so a fourth suite lands as a
# loud "applied 4 times, want 3".
doc, hits = sub_count(r' "clipboard",', "", IOS_LANE_TEXT)
ios_applied(hits, "the guest-list removal", 3)
ios_selftest(RUN_SIM, "no clipboard leg found",
             "a lane with no clipboard leg", mod=load_lane_copy(doc))

# ...and a live host-pasteboard line must fail: the seed once rode
# host-side copy tools and raced both its own delivery window and
# (under validate-all) the mac lane's legs.
doc, hits = sub_count(r'(?m)^KAYA_BUNDLE_PREFIX = "dev\.kaya\."$',
                      'KAYA_BUNDLE_PREFIX = "dev.kaya."\n'
                      'got = out_of(["pbcopy"])', RUN_SIM)
ios_applied(hits, "the host-pasteboard perturbation")
ios_selftest(doc, "touches a pasteboard tool",
             "a live pbcopy in the runner")

# ...and a runner that never asks whether the board is the device's
# own must fail: with Simulator.app running, it is Simulator.app's
# too.
doc, hits = sub_count(
    r"(?m)^    if not clip_relay_check\(UDIDS\[0\], PAD_UDID\):\n"
    r"        sys\.exit\(1\)\n", "", RUN_SIM)
ios_applied(hits, "the relay-check removal")
ios_selftest(doc, "nothing measures the clipboard isolation",
             "a runner that never measures the isolation")

# ...and a queue that stops joining the preparation first would queue
# legs before the isolation is measured.
doc, hits = sub_count(
    r"(?m)^    prep_join\(\)\n(?=    _leg_names\.append)", "", RUN_SIM)
ios_applied(hits, "the queue-join removal")
ios_selftest(doc, "without joining the device preparation",
             "a queue that skips the preparation join")

# ...and the picker half, with its own refusals.
doc, hits = sub_count(r"for _udid in UDIDS:", "for _udid in UDIDS[:1]:",
                      RUN_SIM)
ios_applied(hits, "the one-device picker preparation")
picker_selftest(doc, "not prepared once per phone pool UDID",
                "a runner that admits only one pool device")

# Prior-run app containers must leave before the probe judges
# LocalStorage.
doc, hits = sub_count(
    r"(?m)^    if not picker_cleanup\(udid\):\n        return 1\n", "",
    RUN_SIM)
ios_applied(hits, "the prior-run app cleanup call")
picker_selftest(doc, "does not clean every prior-run kaya app",
                "a picker admission that leaves old app containers "
                "installed")

doc, hits = sub_count(r'(?m)^KAYA_BUNDLE_PREFIX = "dev\.kaya\."$',
                      'KAYA_BUNDLE_PREFIX = "dev."', RUN_SIM)
ios_applied(hits, "the exact kaya bundle cleanup scope")
picker_selftest(doc, "not scoped exactly to the dev.kaya. bundle "
                     "prefix",
                "a cleanup broad enough to uninstall unrelated apps")

doc, hits = sub_count(
    r"return \[b for b in sorted\(apps\) "
    r"if b\.startswith\(KAYA_BUNDLE_PREFIX\)\]",
    "return []", RUN_SIM)
ios_applied(hits, "the prior-run app census emitter")
picker_selftest(doc, "not scoped exactly to the dev.kaya. bundle "
                     "prefix",
                "a census that silently emits no installed kaya apps")

doc, hits = sub_count(r"if remaining:", "if False:", RUN_SIM)
ios_applied(hits, "the cleanup postcondition")
picker_selftest(doc, "does not use bounded simctl uninstalls and "
                     "verify",
                "a cleanup that never refuses a surviving kaya app")

doc, hits = sub_count(
    r"(?m)^(def picker_cleanup\(udid\):\n)",
    '\\1    run(["xcrun", "simctl", "delete", udid])\n', RUN_SIM)
ios_applied(hits, "the destructive cleanup insertion")
picker_selftest(doc, "does not use bounded simctl uninstalls and "
                     "verify",
                "a cleanup that deletes a whole simulator")

doc, hits = sub_count(r'"uninstall", udid,', '"uninstall", "booted",',
                      RUN_SIM)
ios_applied(hits, "the bounded per-device uninstall")
picker_selftest(doc, "does not use bounded simctl uninstalls and "
                     "verify",
                "an uninstall aimed at the ambient booted simulator")

# Exactly two attempts: taking away the post-reseed proof must fail.
doc, hits = sub_count(
    r"(?m)(^    if not picker_reseed\(udid\) or not picker_warm\(udid\):\n"
    r"        return 1\n)    rc = picker_export_probe\(udid\)\n", r"\1",
    RUN_SIM)
ios_applied(hits, "the post-reseed export removal")
picker_selftest(doc, "exactly two warmed export attempts",
                "a picker preparation that trusts its reseed without "
                "probing")

# The slow-flow re-run is on code 76 alone: a re-run on any failure
# would turn the measured stale export into two probes of a stale
# device and then a reseed of it anyway, quietly doubling the wait.
doc, hits = sub_count(r"if rc == 76:", "if rc != 0:", RUN_SIM)
ios_applied(hits, "the unguarded slow re-run", want=2)
picker_selftest(doc, "exactly two warmed export attempts",
                "a picker preparation that re-probes on every failure")

# And once: a third probe of the same warmed device is the open-ended
# retry the rule refuses.
doc, hits = sub_count(
    r"(?m)^(    if rc == 76:\n        # Once more.*\n(?:        #.*\n)*"
    r"        print\(f\"run-sim: re-probing \{udid\} after a slow export flow\",\n"
    r"              file=sys\.stderr\)\n        rc = picker_export_probe\(udid\)\n)",
    r"\1        if rc == 76:\n            rc = picker_export_probe(udid)\n",
    RUN_SIM)
ios_applied(hits, "the third slow re-run")
picker_selftest(doc, "exactly two warmed export attempts",
                "a picker preparation that re-probes a slow device twice")

# Recovery must stay on the one device that failed admission.
doc, hits = sub_count(r'"erase", udid', '"erase", "all"', RUN_SIM)
ios_applied(hits, "the broad picker reseed")
picker_selftest(doc, "exactly $udid",
                "a picker recovery that erases every simulator")

# The host must drive the name field before Save; picker disappearance
# alone cannot prove the intended destination was materialized.
doc, hits = sub_count(r'"savename", probe_name\],', '"savepress"],',
                      RUN_SIM)
ios_applied(hits, "the export-name drive removal")
picker_selftest(doc, "no longer drives and classifies",
                "an export probe that never verifies its destination "
                "name")

doc, hits = sub_count(
    r'\s*or "didPickDocumentURLs called with nil or 0 URLS"\n'
    r"\s*in haystack", "", RUN_SIM)
ios_applied(hits, "the empty-materialization log removal")
picker_selftest(doc, "no longer drives and classifies",
                "an export probe that ignores UIKit's "
                "empty-materialization log")

# Recovery may race neither the clipboard measurement nor recording.
doc, hits = sub_count(
    r"(?m)^    if not clip_relay_check\(UDIDS\[0\], PAD_UDID\):\n"
    r"        sys\.exit\(1\)\n", "", RUN_SIM)
ios_applied(hits, "the final-state relay removal half")
doc, hits = sub_count(
    r"(?m)^    _prep_joined = True\n",
    "    _prep_joined = True\n"
    "    if not clip_relay_check(UDIDS[0], PAD_UDID):\n"
    "        sys.exit(1)\n", doc)
ios_applied(hits, "the early relay insertion half")
picker_selftest(doc, "before device recovery has finished",
                "clipboard isolation measured before a possible "
                "reseed")

doc, hits = sub_count(
    r'(?m)^if os\.environ\.get\("KAYA_RECORD"\):\n    prep_join\(\)\n'
    r"(?=rec_suite_start\(\))", "", RUN_SIM)
ios_applied(hits, "the recording join removal")
picker_selftest(doc, "recording can start before picker recovery",
                "a recorder started while recovery may erase its "
                "device")

# The app side must export, reopen exact bytes, and keep cancel red.
doc, hits = sub_count(
    r"UIDocumentPickerViewController\(forExporting: \[source\], "
    r"asCopy: true\)",
    "UIDocumentPickerViewController(forOpeningContentTypes: "
    "[UTType.item])", EXPORT_PROBE)
ios_applied(hits, "the export-initializer replacement")
picker_selftest(RUN_SIM, "no longer requires a nonempty callback",
                "an admission app that opens instead of exporting",
                probe_text=doc)

doc, hits = sub_count(r"guard copied == payload else",
                      "guard !copied.isEmpty else", EXPORT_PROBE)
ios_applied(hits, "the exact-byte readback replacement")
picker_selftest(RUN_SIM, "no longer requires a nonempty callback",
                "an admission app that trusts any destination bytes",
                probe_text=doc)

doc, hits = sub_count(r'publish\("empty documentPickerWasCancelled"\)',
                      'publish("ok")', EXPORT_PROBE)
ios_applied(hits, "the cancel-green replacement")
picker_selftest(RUN_SIM, "cancellation kept red",
                "an admission app that calls cancellation healthy",
                probe_text=doc)

# A preparation call moved out of the pool loop must still fail even
# if it exists somewhere in the runner.
doc, hits = sub_count(
    r"(?m)^        _prep_results\[u\] = picker_prepare\(u\)\n", "",
    RUN_SIM)
ios_applied(hits, "the late-prepare removal half")
doc, hits = sub_count(
    r"(?m)^rec_suite_start\(\)\n",
    "rec_suite_start()\npicker_prepare(UDIDS[0])\n", doc)
ios_applied(hits, "the late-prepare insertion half")
picker_selftest(doc, "not prepared once per phone pool UDID",
                "a runner that admits LocalStorage too late")

# The holder's retirement, three ways: the census no longer gating the
# verdict, a release that never touches its file, and a seed whose
# holder gets no release file at all.
doc, hits = sub_count(
    r"(?m)^if not clip_holder_census\(\):\n    status = 1\n", "", RUN_SIM)
ios_applied(hits, "the holder-census removal")
ios_selftest(doc, "does not gate the lane's verdict",
             "a lane whose verdict ignores surviving seed holders")
doc, hits = sub_count(r"(?m)^    release\.touch\(\)\n", "", RUN_SIM)
ios_applied(hits, "the release-touch removal")
ios_selftest(doc, "does not touch the release file",
             "a release that leaves the holder holding")
doc, hits = sub_count(r'"hold", str\(release\)\]', '"hold"]', RUN_SIM)
ios_applied(hits, "the release-file argument removal")
ios_selftest(doc, "hand the new one its release file",
             "a seed whose holder can only expire")
doc, hits = sub_count(r"(?m)^    release\.touch\(\)\n",
                      "    holder.kill()\n", RUN_SIM)
ios_applied(hits, "the kill-instead-of-release replacement")
ios_selftest(doc, "killed rather than released",
             "a holder killed the measured-wrong way")

# The accept direction is the real check itself, immediately below: a
# rule that refused everything would fail here rather than pass
# quietly.
out = clipboard_ios(RUN_SIM, "tools/ios/run-sim.py", ios_lane)
if out:
    print("check-steps: an iOS clipboard leg must own its simulator "
          "for the whole leg (docs/clipboard-plan.md §8 finding 5 — "
          "one pasteboard per device, and the slot lock is this lane's "
          "drain):", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

out = picker_ios(RUN_SIM, "tools/ios/run-sim.py", EXPORT_PROBE,
                 "tools/ios/exportprobe/main.swift")
if out:
    print("check-steps: the iOS lane must admit every phone's real "
          "LocalStorage export before its legs (docs/traps.md — a "
          "live provider can carry a stale item index):",
          file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

# The android clipboard clause's negatives, same discipline. A
# clipboard leg moved onto the lockless tablet must fail...
doc, hits = sub_count(r"(?m)^FLAGS = \{\n",
                      'FLAGS = {\n    "clipboard-compose": '
                      '{"tablet": True},\n', ANDROID_LANE_TEXT)
android_applied(hits, "the tablet-flag perturbation")
android_device_selftest(ANDROID_RUNNER_TEXT, "rides the tablet",
                        "a clipboard leg on the tablet",
                        load_lane_copy(doc))
# ...a claim that stopped taking a slot from the pool must fail...
doc, hits = sub_count(r"_dev_slots\.pop\(0\)", "0",
                      ANDROID_RUNNER_TEXT)
android_applied(hits, "the slot-lock perturbation")
android_device_selftest(doc, "no longer takes a slot",
                        "an unlocked device claim", android_lane)
# ...a worker that stopped releasing its slot must fail...
doc, hits = sub_count(r"(?m)^ {16}_release_device\(slot\)$",
                      "                pass", ANDROID_RUNNER_TEXT)
android_applied(hits, "the claim/release perturbation")
android_device_selftest(doc, "no longer claims and releases",
                        "a worker without the slot bracket",
                        android_lane)
# ...an unwired scene must fail, which takes EVERY suite's clipboard
# leg away — 3 today, STATED so a fourth suite lands loudly.
doc, hits = sub_count(r'"clipboard-(?:compose|jvm|go)", ?', "",
                      ANDROID_LANE_TEXT)
android_applied(hits, "the clipboard roster removal", 3)
android_device_selftest(ANDROID_RUNNER_TEXT, "no clipboard leg found",
                        "a lane with no clipboard leg",
                        load_lane_copy(doc))

# The accept direction is the real check itself: a rule that refused
# everything would fail here rather than pass quietly.
out = clipboard_device(ANDROID_RUNNER_TEXT,
                       "tools/android/run-emulator.py", android_lane)
if out:
    print("check-steps: an android clipboard leg must own its emulator "
          "for the whole leg (docs/clipboard-plan.md §0d, §7 finding 4 "
          "— one clipboard per emulator session, and the slot lock is "
          "this lane's drain):", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


# EVERY ANDROID SCENE SELECTOR NEEDS AN ARM IN THE GUEST. One APK
# hosts every scene, so the leg selects one through `--es
# KAYA_SELFTEST <scene>` and the guest matches it. A name the match
# does not carry used to fall through to the default scene: the leg
# launched, a scene ran, and every step failed against labels from a
# scene nobody selected. The guest now panics on an unknown name; this
# makes it a two-second answer instead of an emulator boot.
#
# THREE APKs, EACH WITH ITS OWN SELECTOR, so the pair is an argument
# rather than a constant.
#
# THE FLOOR IS THE ANTI-VACUITY CLAUSE: the selection comes from the
# lane module's suite roster now, and a moved table answers few or no
# scenes — a census that reads nothing agrees with everything.
def android_selected(mod, suite):
    """The KAYA_SELFTEST value each of a suite's legs passes — the
    bare suite legs pass "1" (the unprefixed milestone2 arm)."""
    return {"1" if leg in mod.SUITES else mod.scene_of(leg)
            for leg in mod.suite_legs(suite)}


def android_scenes(selected, source, guest_text, guest, arm,
                   exempt=()):
    if len(selected) < 5:
        return [f"{source} selects {len(selected)} scene(s) for this "
                f"suite — a roster that small is the module table "
                f"moved, and this clause compared nothing"]
    armed = set(re.findall(arm, guest_text, re.M))
    missing = sorted(set(selected) - armed - set(exempt))
    return [f"{source} selects scene {name!r}, which {guest} has no "
            f"arm for" for name in missing]


# The guard guards itself in every direction: an unarmed selector must
# fail, an emptied selection must fail, and each ARM SHAPE gets its
# own negative — a `match` arm and a map key are different text.
if not android_scenes(
        {"entry", "ghostscene", "zzf1", "zzf2", "zzf3"}, "-",
        'Ok("entry") => entry::app(ctx),\n'
        'Ok("zzf1") | Ok("zzf2") | Ok("zzf3") => entry::app(ctx),\n',
        "-", r'Ok\("([a-z0-9]+)"\)'):
    selftest_fail("an unarmed android selector passed")
if not android_scenes(
        set(), "-", 'Ok("entry") => entry::app(ctx),\n', "-",
        r'Ok\("([a-z0-9]+)"\)'):
    selftest_fail("an EMPTY selection passed — the clause compared "
                  "nothing and said OK")
if not android_scenes(
        {"entry", "ghostscene", "zzf1", "zzf2", "zzf3"}, "-",
        'var scenes = map[string]func() *kaya.App{\n'
        '\t"entry": entry.App,\n\t"zzf1": entry.App,\n'
        '\t"zzf2": entry.App,\n\t"zzf3": entry.App,\n}\n', "-",
        r'^\t"([a-z0-9]+)":'):
    selftest_fail("an unarmed GO scene table passed — the map-key "
                  "pattern is not reading the table")

out = android_scenes(
    android_selected(android_lane, "compose"),
    "tools/lib/lanes/android.py",
    read_rel("guests/rust/milestone2_android.rs"),
    "guests/rust/milestone2_android.rs", r'Ok\("([a-z0-9]+)"\)')
if out:
    print("check-steps: an android leg selects a scene the APK's guest "
          "cannot run:", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

# The JVM APK's selector ends in `else -> Milestone2::app`, so an
# unarmed name does not die — it SILENTLY RUNS MILESTONE2. "1" is
# exempt because it IS that default arm, reached deliberately.
out = android_scenes(
    android_selected(android_lane, "jvm"),
    "tools/lib/lanes/android.py",
    read_rel("android/milestone2kt/src/main/kotlin/dev/kaya/"
             "milestone2kt/MainActivity.kt"),
    "android/milestone2kt/src/main/kotlin/dev/kaya/milestone2kt/"
    "MainActivity.kt", r'"([a-z0-9]+)" ->', exempt=("1",))
if out:
    print("check-steps: an android JVM leg selects a scene "
          "MainActivity.kt has no arm for — it would run milestone2 "
          "instead, silently:", file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1

# The Go APK. Its arms are a map literal, one key per line, which is
# why the table in that file is a table and not a switch. THE SAME
# TABLE SERVES THE DESKTOPS since the guests collapsed into one
# binary, and the clause below reads it from the other three runners.
out = android_scenes(
    android_selected(android_lane, "go"),
    "tools/lib/lanes/android.py",
    read_rel("guests/go/cmd/scenes.go"), "guests/go/cmd/scenes.go",
    r'^\t"([a-z0-9]+)":')
if out:
    print("check-steps: an android Go leg selects a scene the Go "
          "guest does not carry (guests/go/cmd/scenes.go's table):",
          file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


# AND EVERY DESKTOP GO LEG, against the same table: the Go guests are
# one binary now, so the NAME is the only thing that decides what
# runs, and a name the table lacks panics after a build, a launch and
# a window, on three lanes.
#
# THE THREE RUNNERS SPELL THE SELECTION DIFFERENTLY, so each gets its
# own pattern: mac and linux put `KAYA_SELFTEST=<scene>` on the leg
# line (often continued, so continuations are joined first) beside
# go-guests/kaya-go; windows sets it in tools/guest/run_<leg>_go.cmd.
#
# AND THE DEFAULT IS A NAME LIKE ANY OTHER: the bare `run go-swiftui …`
# leg passes nothing, so main_desktop.go falls back to `defaultScene`,
# which has to be a key in this table.
#
# THE EMPTY-SELECTION ARM IS THE ANTI-VACUITY CLAUSE, as above.
def go_desktop_scenes(table_text, table, runners):
    """`runners` is a list of (label, kind, payload): kind "runner"
    carries the runner's text, kind "cmd-dir" a list of (name, text)
    launcher files, kind "selected" a precomputed set of
    KAYA_SELFTEST values (a lane module's go legs) — the three
    spellings the three lanes use."""
    armed = set(re.findall(r'^\t"([a-z0-9]+)":', table_text, re.M))
    bad = []
    if not armed:
        bad.append(f"{table}: no scene table here — the map-key "
                   f"pattern matched nothing, so this clause compared "
                   f"nothing")
    default = re.search(r'^const defaultScene = "([a-z0-9]+)"',
                        table_text, re.M)
    if not default:
        bad.append(f"{table}: no `const defaultScene` — the desktop "
                   f"tail falls back to it when KAYA_SELFTEST is "
                   f"empty, and this clause cannot check a name it "
                   f"cannot find")
    elif armed and default.group(1) not in armed:
        bad.append(f"{table}: defaultScene is {default.group(1)!r}, "
                   f"which the table has no key for — the bare Go leg "
                   f"would panic")
    for label, kind, payload in runners:
        if kind == "cmd-dir":
            selected = set()
            for name, src in payload:
                if "dev.kaya/guests/go/cmd" not in src:
                    bad.append(f"{name}: a go launcher that does not "
                               f"build dev.kaya/guests/go/cmd")
                    continue
                names = re.findall(r"set KAYA_SELFTEST=([A-Za-z0-9]+)",
                                   src)
                if not names:
                    bad.append(f"{name}: builds the Go guest and sets "
                               f"no KAYA_SELFTEST, so it runs whatever "
                               f"the default is")
                selected.update(names)
        elif kind == "selected":
            selected = set(payload)
        else:
            src = payload.replace("\\\n", " ")
            selected = set(re.findall(
                r"KAYA_SELFTEST=([a-z0-9]+)[^\n]*go-guests/kaya-go",
                src))
        if not selected:
            bad.append(f"{label}: names no Go scene — the selection "
                       f"pattern matched nothing, so this clause "
                       f"compared nothing")
            continue
        for name in sorted(selected - armed):
            bad.append(f"{label} runs the Go guest with "
                       f"KAYA_SELFTEST={name}, which {table} has no "
                       f"key for")
    return bad


# Watched failing in every direction it can go wrong: an unarmed name,
# a pattern that matches nothing, a default that is not a scene, and
# the windows spelling — which is a different pattern over different
# files and proves nothing about the shell one.
SAMPLE_TABLE = ('var scenes = map[string]func() *kaya.App{\n'
                '\t"entry": entry.App,\n}\n'
                'const defaultScene = "entry"\n')
if not go_desktop_scenes(
        SAMPLE_TABLE, "-",
        [("-", "runner", "run ghost-go env KAYA_SELFTEST=ghost "
          "target/go-guests/kaya-go\n")]):
    selftest_fail("a desktop Go leg naming a scene the table lacks "
                  "passed")
if not go_desktop_scenes(
        SAMPLE_TABLE, "-",
        [("-", "runner",
          "run rust env target/debug/examples/milestone2\n")]):
    selftest_fail("a runner selecting NO go scene passed — the clause "
                  "compared nothing and said OK")
if not go_desktop_scenes(
        'var scenes = map[string]func() *kaya.App{\n'
        '\t"entry": entry.App,\n}\nconst defaultScene = "nope"\n', "-",
        [("-", "runner", "run entry-go env KAYA_SELFTEST=entry "
          "target/go-guests/kaya-go\n")]):
    selftest_fail("a defaultScene with no key in the table passed — "
                  "the bare Go leg is the one that would die")
if not go_desktop_scenes(
        SAMPLE_TABLE, "-",
        [("-", "cmd-dir", [("run_ghost_go.cmd",
          "set KAYA_SELFTEST=ghost\ngo build -o C:\\kaya\\ghost_go.exe "
          "dev.kaya/guests/go/cmd\n")])]):
    selftest_fail("a windows launcher naming a scene the table lacks "
                  "passed — the .cmd pattern is not reading the "
                  "launchers")
if go_desktop_scenes(
        SAMPLE_TABLE, "-",
        [("-", "runner", "run entry-go env KAYA_SELFTEST=entry "
          "target/go-guests/kaya-go\n")]):
    selftest_fail("a leg naming an armed scene was refused")
# ...and the module spelling — the mac queue is a lanes module now,
# and its go selection is a derived set rather than a text pattern.
if not go_desktop_scenes(SAMPLE_TABLE, "-",
                         [("-", "selected", {"ghost"})]):
    selftest_fail("a module go leg naming a scene the table lacks "
                  "passed")
if not go_desktop_scenes(SAMPLE_TABLE, "-",
                         [("-", "selected", set())]):
    selftest_fail("an EMPTY module go selection passed — the clause "
                  "compared nothing and said OK")

mac_go_selected = {"1" if scene == "milestone2" else scene
                   for _n, scene, lang in mac_lane.legs()
                   if lang == "go"}
out = go_desktop_scenes(
    read_rel("guests/go/cmd/scenes.go"), "guests/go/cmd/scenes.go",
    [("tools/lib/lanes/mac.py", "selected", mac_go_selected),
     ("tools/linux/run-suites.sh", "runner",
      read_rel("tools/linux/run-suites.sh")),
     ("tools/guest", "cmd-dir",
      [(str(p.relative_to(ROOT)), p.read_text(encoding="utf-8"))
       for p in sorted((ROOT / "tools" / "guest").glob("*_go.cmd"))])])
if out:
    print("check-steps: a desktop Go leg selects a scene the one Go "
          "binary does not carry (guests/go/cmd/scenes.go's table):",
          file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


# THE iOS PICKER'S SILENT WIRINGS. Each of these fails in a way that
# looks like a backend bug rather than a harness one. (The file_mode
# clause lives in tools/check-file-modes.sh, which reads the numbers
# out of crates/kaya/src/spec.rs rather than hard-coding them.)
def ios_picker():
    bad = []
    # 1. THE ACCESSIBILITY TOKEN MUST BE RETIRED. Every response from
    #    sendAccessibilityRequestAsync: goes back through
    #    _resetBridgeTokensForResponse:. Drop it and NOTHING looks
    #    wrong: the reads keep working and the next TAP is silently
    #    ignored, so the call that proves the transport works is the
    #    one that hides the bug. Measured 2026-07-31 (docs/traps.md).
    simdrive = read_rel("tools/ios/simdrive/main.swift")
    if "sendAccessibilityRequestAsync" in simdrive \
            and "_resetBridgeTokensForResponse" not in simdrive:
        bad.append("tools/ios/simdrive/main.swift reads accessibility "
                   "but never retires the token "
                   "(_resetBridgeTokensForResponse:) — the reads would "
                   "keep working and every tap would be silently "
                   "ignored")
    # 2. THE BUNDLE MUST PUBLISH ITS DOCUMENTS. Without both keys the
    #    document picker cannot see the app own files at all, and a
    #    picker aimed at them opens somewhere else with no error
    #    anywhere.
    plist = read_rel("tools/ios/Info.plist.in")
    for key in ("UIFileSharingEnabled",
                "LSSupportsOpeningDocumentsInPlace"):
        if key not in plist:
            bad.append(f"tools/ios/Info.plist.in is missing {key} — "
                       f"the picker could not browse the app own "
                       f"Documents and the filedialog leg would fail "
                       f"as though the backend were wrong")
    return bad


out = ios_picker()
if out:
    print("check-steps: the iOS picker wiring has a silent hole:",
          file=sys.stderr)
    print("\n".join(out), file=sys.stderr)
    status = 1


# THE GENERATOR MUST NOT OUTRUN WHAT IT GENERATED. gen-bindings.sh
# stamps a hash of tools/kaya-bindgen/src/*.rs beside the bindings it
# wrote; if the generator moved since, the checked-in bindings are
# stale and everything downstream is a lie that COMPILES
# (docs/traps.md). `gen-bindings.sh --check` is the authoritative
# answer and regenerates to get it; this is the cheap one, so it can
# be asked constantly.
def generator_stamp(root):
    root = pathlib.Path(root)
    h = hashlib.sha256()
    for p in sorted((root / "tools" / "kaya-bindgen" / "src")
                    .glob("*.rs")):
        h.update(p.read_bytes())
    want = h.hexdigest()[:16]
    stamp = root / "bindings" / ".generator-id"
    have = (stamp.read_text(encoding="utf-8").strip()
            if stamp.is_file() else "")
    if want != have:
        return (f"the binding generator has changed since the bindings "
                f"were generated (generator {want}, bindings say "
                f"{have or '<no stamp>'}) — run tools/gen-bindings.sh")
    return None


# The guard guards itself: a moved generator must be caught.
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    (d / "tools/kaya-bindgen/src").mkdir(parents=True)
    (d / "bindings").mkdir()
    (d / "tools/kaya-bindgen/src/main.rs").write_text(
        "// a generator that moved\n", encoding="utf-8")
    (d / "bindings/.generator-id").write_text("0000000000000000\n",
                                              encoding="utf-8")
    if generator_stamp(d) is None:
        selftest_fail("a stale generator stamp passed")

stamp_out = generator_stamp(ROOT)
if stamp_out is not None:
    print(f"check-steps: {stamp_out}", file=sys.stderr)
    status = 1

if status == 0:
    print("check-steps: OK")
raise SystemExit(status)

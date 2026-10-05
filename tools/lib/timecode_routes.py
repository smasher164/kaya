"""docs/number-field-plan.md §10: one formatter and parser on every backend."""

import functools
import re

from kaya_gate import ROOT

CORE = "crates/kaya/src/number_field.rs"
CAPI = "crates/kaya/src/capi.rs"
HOST = "crates/kaya/src/swiftui_host.rs"
JNI = "crates/kaya/src/android.rs"
GTK = "crates/kaya/src/gtk.rs"
WIN = "crates/kaya/src/winui/mod.rs"
SWIFT = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"


@functools.lru_cache(maxsize=24)
def masked(source, strings=False):
    chars = list(source)
    at = 0
    candidate = re.compile(r'//|/\*|\b(?:br|r)#{0,16}"|["\']')
    while at < len(source):
        next_token = candidate.search(source, at)
        if next_token is None:
            break
        at = next_token.start()
        end = at
        comment = False
        if source.startswith("//", at):
            end = source.find("\n", at)
            if end < 0:
                end = len(source)
            comment = True
        elif source.startswith("/*", at):
            depth = 1
            end = at + 2
            while end < len(source) and depth:
                if source.startswith("/*", end):
                    depth += 1
                    end += 2
                elif source.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            comment = True
        elif source.startswith('"""', at):
            close = source.find('"""', at + 3)
            end = len(source) if close < 0 else close + 3
        else:
            raw = re.match(r'(?:br|r)(#{0,16})"', source[at:at + 20])
            char = re.match(r"(?:b)?'(?:\\.|[^'\\\n])'", source[at:at + 8])
            if raw and (at == 0 or not source[at - 1].isalnum()):
                terminator = '"' + raw.group(1)
                close = source.find(terminator, at + raw.end())
                end = len(source) if close < 0 else close + len(terminator)
            elif char:
                end = at + char.end()
            elif source[at] == '"':
                end = at + 1
                while end < len(source):
                    if source[end] == "\\":
                        end += 2
                    elif source[end] == '"':
                        end += 1
                        break
                    else:
                        end += 1
        if end > at:
            if strings or comment:
                chars[at:end] = ["\n" if c == "\n" else " " for c in source[at:end]]
            at = end
        else:
            at += 1
    return "".join(chars)


def scope(source, owners):
    start, end = 0, len(source)
    clean = masked(source)
    structural = masked(source, True)
    for owner in owners:
        hits = list(re.finditer(re.escape(owner), clean[start:end]))
        if len(hits) != 1:
            return None
        at = start + hits[0].start()
        opening = (at + len(owner) - 1 if owner.endswith("{")
                   else structural.find("{", at + len(owner), end))
        if opening < 0:
            return None
        depth = 1
        closing = opening + 1
        while closing < end and depth:
            depth += (structural[closing] == "{") - (structural[closing] == "}")
            closing += 1
        if depth:
            return None
        start, end = opening, closing
    return start, end


def pattern(needle):
    return r"\s*".join(re.escape(t) for t in re.findall(r"\w+|[^\w\s]", needle))


ROUTES = []


def route(label, path, owners, needle):
    ROUTES.append((label, path, tuple(owners), needle))


for function, needle in (
    ("text_for", "fmt::timecode(frames, rate)"),
    ("parse_for", "NumberFormat::Timecode(rate) => fmt::parse_timecode(text, rate)"),
    ("commit_for", "parse_for(text, format)"),
    ("commit_for", "bounds_for(min, max, format)"),
    ("stepped_for", "bounds_for(min, max, format)"),
    ("bounds_for", "NumberFormat::Timecode(_) => (min.max(0.0), max.min(fmt::MAX_TIMECODE_FRAMES as f64))"),
):
    route("core " + function + " " + needle.split("(")[0], CORE, ["fn " + function + "("], needle)
for function, needle in (
    ("kaya_fmt_timecode", "crate::fmt::timecode(frames, rate)"),
    ("kaya_fmt_parse_timecode", "crate::fmt::parse_timecode(text, rate)"),
):
    route("C " + function, CAPI, ["fn " + function + "("], needle)
    route("C rate " + function, CAPI, ["fn " + function + "("],
          "timecode_rate(numerator, denominator, drop_frame)")
route("host format parser", HOST, ["fn number_format("], "crate::fmt::NumberFormat::from_wire(text)")
for function, needle in (
    ("number_text", "crate::number_field::text_for(value, step, unsafe { number_format(format) })"),
    ("number_commit", "crate::number_field::commit_for(&text, committed, min, max, step, unsafe { number_format(format) })"),
    ("number_step", "crate::number_field::stepped_for(committed, steps, min, max, step, unsafe { number_format(format) })"),
):
    route("host " + function, HOST, ["fn " + function + "("], needle)
for function, needle in (
    ("present_number_text", "crate::number_field::text_for(value, step, format)"),
    ("present_number_commit", "crate::number_field::commit_for(&text, committed, min, max, step, format)"),
):
    owner = "fn " + function + ("<'a>(" if function == "present_number_text" else "(")
    route("JNI " + function, JNI, [owner], needle)
    route("JNI format " + function, JNI, [owner], "crate::fmt::NumberFormat::from_wire(&format)")

route("C user value", CAPI, ["fn kaya_emit_value_committed("],
      "scene.user_number_committed(tag, value); } if let Some(sink) = PRESENTATION_SINK.lock().unwrap().as_ref() {")
for name, path, prefix, owner, args in (
    ("GTK", GTK, "gtk", "fn number_committed(", "tag, moved"),
    ("WinUI", WIN, "winui", "fn winui_number_settle(", "&cell.tag, v"),
):
    route(name + " user value before event", path, [owner],
          prefix + "_user_number_committed(" + args + "); sink.send_value_committed_tag(" + args + ");")
    route(name + " user value core", path, ["fn " + prefix + "_user_number_committed("],
          "core.scene.user_number_committed(tag, value)")
    route(name + " user value queued", path, ["fn " + prefix + "_user_number_committed("],
          "NUMBER_SETTLED.with_borrow_mut(|queue| queue.push((tag.to_vec(), value)))")
    route(name + " user value drained", path, ["fn drain_number_settled("],
          "for (tag, value) in NUMBER_SETTLED.with_borrow_mut(std::mem::take) { core.scene.user_number_committed(&tag, value); }")
    route(name + " user value before apply", path, ["fn drain_transactions("],
          "drain_number_settled(core); for op in core.scene.apply(tx) {")
route("GTK harness user value before apply", GTK, ["fn type_text("],
      "drain_number_settled(core); for op in core.scene.apply(tx) {")

GTK_CREATE = ["fn apply(", "WidgetKind::NumberField => {"]
route("GTK output", GTK, GTK_CREATE + ["spin.connect_output(move |sb| {"],
      "crate::number_field::text_for(sb.value(), state.step, state.format)")
route("GTK input", GTK, GTK_CREATE + ["spin.connect_input(move |sb| {"],
      "crate::number_field::commit_for(&text, state.committed, adjustment.lower(), adjustment.upper(), state.step, state.format,)")
route("GTK bounds", GTK, ["fn number_reconfigure("],
      "crate::number_field::bounds_for(state.min, state.max, state.format)")
route("GTK refresh", GTK, ["fn number_reconfigure("],
      "crate::number_field::text_for(state.committed, state.step, state.format,)")
for label, needle in (
    ("parser", "state.format = crate::fmt::NumberFormat::from_wire(&s)"),
    ("write", "field.state.set(state)"),
    ("refresh", "number_reconfigure(field)"),
):
    route("GTK format " + label, GTK,
          ["fn apply(", "(NativeWidget::NumberField(field), Prop::Format, Value::Str(s)) => {"], needle)
route("WinUI output", WIN, ["impl KayaNumberText_Impl {", "fn write("],
      "crate::number_field::text_for(value, SliderCell::get(&self.cell.step), self.cell.format())")
route("WinUI input", WIN, ["impl KayaNumberText_Impl {", "fn read("],
      "crate::number_field::parse_for(&text.to_string(), self.cell.format())")
route("WinUI bounds", WIN, ["impl NumberCell {", "fn numbers("],
      "crate::number_field::bounds_for(SliderCell::get(&self.min), SliderCell::get(&self.max), self.format(),)")
route("WinUI formatter installed", WIN, ["fn winui_number_shape("], "field.SetNumberFormatter(&text)")
for label, needle in (
    ("parser", "crate::fmt::NumberFormat::from_wire(&s)"),
    ("write", '*cell.format.lock().expect("number field format lock") ='),
    ("refresh", "winui_number_shape(field, cell, &core.apply_quiet)"),
):
    route("WinUI format " + label, WIN,
          ["fn apply(", "(NativeWidget::NumberField(field), Prop::Format, Value::Str(s)) => {"], needle)

for label, owners, needle in (
    ("text size", ["func kayaNumberText("], "KayaHost.api.number_text(value, step, format, UnsafeMutablePointer<UInt8>(nil), 0)"),
    ("text bytes", ["func kayaNumberText("], "KayaHost.api.number_text(value, step, format, p.baseAddress, UInt(needed))"),
    ("commit", ["func kayaNumberCommit("], "KayaHost.api.number_commit(p.baseAddress, UInt(p.count), node.value, node.minValue, node.maxValue, node.step, format, &moved)"),
    ("step", ["func kayaNumberStep("], "KayaHost.api.number_step(node.value, steps, node.minValue, node.maxValue, node.step, format, &moved)"),
    ("settle", ["func kayaNumberSettle("], "kayaNumberText(node.value, node.step, node.numberFormat)"),
    ("format apply", ["func kayaApply("], "case (propFormat, valueStr): let node = kayaScene.nodes[id]! node.numberFormat = String(decoding: raw[(body + 24)..<(body + 24 + len)], as: UTF8.self) numberWrites.insert(id)"),
    ("value apply", ["func kayaApply("], "kayaScene.nodes[id]!.committed = kayaScene.nodes[id]!.value if kayaScene.nodes[id]!.kind == kindNumberField { numberWrites.insert(id) }"),
    ("step apply", ["func kayaApply("], "case (propStep, valueF64): kayaScene.nodes[id]!.step = raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self) if kayaScene.nodes[id]!.kind == kindNumberField { numberWrites.insert(id) }"),
    ("batch refresh", ["func kayaApply(", "for id in numberWrites {"], "node.text = kayaNumberText(node.value, node.step, node.numberFormat)"),
):
    route("Swift " + label, SWIFT, owners, needle)
for function in ("kayaNumberCommit", "kayaNumberStep"):
    route("Swift format " + function, SWIFT, ["func " + function + "("], "node.numberFormat.withCString { format in")
route("Swift format text", SWIFT, ["func kayaNumberText("], "format.withCString { format in")

for label, owners, needle in (
    ("commit", ["fun kayaNumberCommit("], "KayaPresent.numberCommit(node.textState.text.toString(), node.value, node.minValue, node.maxValue, node.step, node.numberFormat, out)"),
    ("settle", ["fun kayaNumberSettle("], "KayaPresent.numberText(node.value, node.step, node.numberFormat)"),
    ("format apply", ["private fun apply(", "PROP_FORMAT -> {"], "node.numberFormat = readString(b) numberWrites.add(id)"),
    ("value apply", ["private fun apply(", "PROP_VALUE -> {"], "if (node.kind == KIND_NUMBER_FIELD) { numberWrites.add(id) }"),
    ("step apply", ["private fun apply(", "PROP_STEP -> {"], "if (node.kind == KIND_NUMBER_FIELD) { numberWrites.add(id) }"),
    ("batch refresh", ["private fun apply(", "for (id in numberWrites) {"], "KayaPresent.numberText(node.value, node.step, node.numberFormat)"),
):
    route("Compose " + label, COMPOSE, owners, needle)


for function in ("number_text", "number_commit", "number_step"):
    route("host installed " + function, HOST, ["fn run(", "let api = KayaHostApi {"], function + ",")
for name, signature, function in (
    ("numberText", "(DDLjava/lang/String;)Ljava/lang/String;", "present_number_text"),
    ("numberCommit", "(Ljava/lang/String;DDDDLjava/lang/String;[D)I", "present_number_commit"),
):
    route("JNI installed " + name, JNI, ["fn register_present_natives("],
          'name: "' + name + '".into(), sig: "' + signature + '".into(), fn_ptr: ' + function + ' as *mut _,')
route("Swift format constant", SWIFT, [], "private let propFormat: UInt32 = 55")
route("Compose format constant", COMPOSE, [], "private const val PROP_FORMAT = 55")

LOCAL_PARSERS = (
    (HOST, ("fn number_text(",)),
    (HOST, ("fn number_commit(",)),
    (HOST, ("fn number_step(",)),
    (JNI, ("fn present_number_text<'a>(",)),
    (JNI, ("fn present_number_commit(",)),
    (GTK, tuple(GTK_CREATE + ["spin.connect_output(move |sb| {"])),
    (GTK, tuple(GTK_CREATE + ["spin.connect_input(move |sb| {"])),
    (WIN, ("impl KayaNumberText_Impl {", "fn write(")),
    (WIN, ("impl KayaNumberText_Impl {", "fn read(")),
    (SWIFT, ("func kayaNumberText(",)),
    (SWIFT, ("func kayaNumberCommit(",)),
    (SWIFT, ("func kayaNumberStep(",)),
    (COMPOSE, ("fun kayaNumberCommit(",)),
    (COMPOSE, ("fun kayaNumberSettle(",)),
)
OWN_PARSE = re.compile(
    r"\.split(?:_once)?\s*\(|\b(?:NumberFormatter|DecimalFormatter|DateFormatter|DateTimeFormatter)\b|"
    r"\b(?:17982|1798|179820|35964|3596)\b|crate::fmt::(?:number|parse_number)\s*\(")


def local_findings(sources, paths=LOCAL_PARSERS):
    for path, owners in paths:
        source = sources.get(path)
        if source is None:
            yield f"timecode local parser: cannot read {path}"
            continue
        span = scope(source, owners)
        if span is None:
            yield f"timecode local parser: missing owner {owners[-1]} in {path}"
        elif OWN_PARSE.search(masked(source)[span[0]:span[1]]):
            yield f"timecode local parser: {owners[-1]} in {path} must use the core formatter"


def findings(sources, routes=ROUTES):
    for label, path, owners, needle in routes:
        source = sources.get(path)
        if source is None:
            yield f"timecode {label}: cannot read {path}"
            continue
        span = scope(source, owners)
        if span is None:
            yield f"timecode {label}: missing or ambiguous owner in {path}"
            continue
        body = masked(source)[span[0]:span[1]]
        if len(list(re.finditer(pattern(needle), body))) != 1:
            yield f"timecode {label}: core route or format argument missing in {path}"
    for path, owner, loop in (
        (SWIFT, "func kayaApply(", "while at + 8 <= raw.count {"),
        (COMPOSE, "private fun apply(", "while (b.remaining() >= 8) {"),
    ):
        if path not in sources:
            continue
        source = sources[path]
        batch = scope(source, [owner])
        body = scope(source, [owner, loop])
        refresh = scope(source, [owner, "for id in numberWrites {" if path == SWIFT else "for (id in numberWrites) {"])
        if not batch or not body or not refresh or refresh[0] <= body[1]:
            yield f"timecode batch boundary: number refresh must follow the apply loop in {path}"


def run(g):
    sources = {}
    for path in sorted({r[1] for r in ROUTES}):
        try:
            sources[path] = (ROOT / path).read_text(encoding="utf-8")
        except OSError as exc:
            g.refuse(f"timecode routes cannot read {path}: {exc}")
    g.counted("timecode route files", sources, floor=8)
    g.counted("timecode core routes", ROUTES, floor=69)
    baseline = list(findings(sources)) + list(local_findings(sources))
    if baseline:
        for line in baseline:
            g.finding(line)
        g.refuse("timecode route baseline must pass before watched cuts")
    watched = 0
    for row in ROUTES:
        label, path, owners, needle = row
        source = sources[path]
        start, end = scope(source, owners)
        body = source[start:end]
        match = re.search(pattern(needle), masked(body))
        if match is None:
            g.refuse("timecode mutation could not locate " + label)
        broken = g.doctor("timecode " + label, body,
                          re.escape(body[match.start():match.end()]), "route_removed")
        changed = source[:start] + broken + source[end:]
        g.negative("timecode " + label, lambda row=row, path=path, changed=changed:
                   findings({path: changed}, [row]), want="timecode " + label + ":")
        watched += 1
    for path in (SWIFT, COMPOSE):
        source = sources[path]
        refresh = "for id in numberWrites {" if path == SWIFT else "for (id in numberWrites) {"
        loop = "while at + 8 <= raw.count {" if path == SWIFT else "while (b.remaining() >= 8) {"
        owner = "func kayaApply(" if path == SWIFT else "private fun apply("
        start, end = scope(source, [owner, refresh])
        block = source[start:end]
        moved = g.doctor("timecode refresh moved inside apply " + path, source,
                         re.escape(refresh) + re.escape(block[1:]), "")
        moved = g.doctor("timecode refresh inserted before loop ends " + path, moved,
                         re.escape(loop), lambda m: m.group() + "\n" + refresh[:-1] + block)
        g.negative("timecode premature refresh " + path,
                   lambda path=path, moved=moved: findings({path: moved}, []),
                   want="timecode batch boundary:")
        watched += 1
    for path, owners in LOCAL_PARSERS:
        source = sources[path]
        start, end = scope(source, owners)
        body = source[start:end]
        broken = g.doctor("timecode own parser " + owners[-1], body, r"^\{",
                          '{ text.split(":");')
        changed = source[:start] + broken + source[end:]
        g.negative("timecode own parser " + owners[-1],
                   lambda path=path, owners=owners, changed=changed:
                   local_findings({path: changed}, [(path, owners)]),
                   want="must use the core formatter")
        watched += 1
    missing = g.doctor("timecode missing reader", sources[WIN],
                       re.escape("fn read(&self, text: &HSTRING)"), "fn missing_reader(&self, text: &HSTRING)")
    reader = next(row for row in ROUTES if row[0] == "WinUI input")
    g.negative("timecode missing reader", lambda: findings({WIN: missing}, [reader]),
               want="missing or ambiguous owner")
    watched += 1
    g.negative("timecode missing source", lambda: findings({}, [reader]), want="cannot read")
    watched += 1
    g.counted("timecode watched route negatives", watched, floor=len(ROUTES) + len(LOCAL_PARSERS) + 4)

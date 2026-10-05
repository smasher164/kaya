"""The caption recorder's measured publication, callback and native reads."""

import re

from kaya_gate import ROOT
from timecode_routes import masked, pattern, scope

GTK = "crates/kaya/src/gtk.rs"
MEDIA = "crates/kaya/src/media.rs"
SCENE = "crates/kaya/src/scene.rs"
JAVA = "guests/java/dev/kaya/guests/Media.java"
ROUTES = []


def route(label, path, owners, needle):
    ROUTES.append((label, path, tuple(owners), needle))


for label, needle in (
    ("read-only snapshot", "let p = self.players.get(&player)?;"),
    ("cue boundaries", "p.sidecar.as_ref().map_or_else(Vec::new, Captions::boundaries)"),
    ("clock optional", "sidecar_expected: t_ms.map(|t| match (&p.sidecar, p.sidecar_selected)"),
    ("core cue reader", "(Some(c), true) => c.text_at(t)"),
    ("published cue", "published: p.cue.clone()"),
):
    route(label, MEDIA, ["fn caption_snapshot(&self,"], needle)
route("scene snapshot forwarding", SCENE, ["fn caption_snapshot(&self,"],
      "self.media.caption_snapshot(player, t_ms)")
for label, needle in (
    ("publication clock", "let query_ms = p.pb().query_position::<gst::ClockTime>().map(|t| t.mseconds());"),
    ("publication actual clock", "core.scene.caption_at(crate::protocol::PlayerId(id), at)"),
    ("publication diagnostic", "KAYA_DIAG caption_publish wall_ms="),
    ("publication snapshot", "core.scene.caption_snapshot(crate::protocol::PlayerId(id), query_ms)"),
    ("publication count", "published.len()"),
):
    route(label, GTK, ["fn caption_ask("], needle)
route("schedule diagnostic", GTK, ["fn schedule_boundary("], "KAYA_DIAG caption_schedule wall_ms=")
route("boundary diagnostic", GTK, ["fn schedule_boundary("], "KAYA_DIAG caption_boundary wall_ms=")
route("stage actual read", GTK, ["fn caption(&self,"], "gtk_media::drawn_caption(core, &core.videos[i])")
for label, needle in (
    ("native visible", "let visible = view.caption.is_visible();"),
    ("native text", "let native_text = view.caption.text().to_string();"),
    ("returned capture", "let returned = if visible { native_text.clone() } else { String::new() };"),
    ("read clock", "let query_ms = p.as_ref().and_then(|p| p.pb().query_position::<gst::ClockTime>()).map(|t| t.mseconds());"),
    ("read snapshot", "core.scene.caption_snapshot(crate::protocol::PlayerId(id), query_ms)"),
    ("read cache", "p.inner.borrow().kaya_caption.clone()"),
    ("read diagnostic", "KAYA_DIAG caption_read wall_ms="),
    ("read returned value", "caption_wall_ms()); returned }"),
):
    route(label, GTK, ["fn drawn_caption("], needle)
route("label application", GTK,
      ["fn apply(", "(NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {"],
      "gtk_media::caption_label_applied(id.0, &label.text())")
route("label diagnostic", GTK, ["fn caption_label_applied("], "KAYA_DIAG caption_label_apply wall_ms=")
route("Java callback", JAVA, ["void tracksApp(", "app.onCue(player, (t, text) -> {", 'if ("media_tracks".equals(System.getenv("KAYA_SELFTEST"))) {'],
      "KAYA_DIAG caption_callback wall_ms=")
route("Java clock", JAVA, ["void tracksApp(", "app.onCue(player, (t, text) -> {", 'if ("media_tracks".equals(System.getenv("KAYA_SELFTEST"))) {'],
      "System.currentTimeMillis()")
route("Java actual cue", JAVA, ["void tracksApp(", "app.onCue(player, (t, text) -> {", 'if ("media_tracks".equals(System.getenv("KAYA_SELFTEST"))) {'],
      "text.getBytes(java.nio.charset.StandardCharsets.UTF_8)")


def findings(sources, routes=ROUTES):
    for label, path, owners, needle in routes:
        if path not in sources:
            yield f"caption {label}: cannot read {path}"
            continue
        source = sources[path]
        span = scope(source, owners)
        if span is None:
            yield f"caption {label}: missing or ambiguous owner in {path}"
            continue
        body = masked(source)[span[0]:span[1]]
        if len(list(re.finditer(pattern(needle), body))) != 1:
            yield f"caption {label}: measured route missing in {path}"


def ordering_findings(sources):
    for label, path, owners, before, after in (
        ("publish before send", GTK, ["fn caption_ask("], "caption_publish", "core.occurrences.send(occ)"),
        ("callback before write", JAVA, ["void tracksApp(", "app.onCue(player, (t, text) -> {"], "caption_callback", "t.write(cue, text)"),
        ("label after apply", GTK, ["fn apply(", "(NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {"], "label.set_text(&s)", "caption_label_applied"),
    ):
        source = sources.get(path, "")
        span = scope(source, owners)
        body = masked(source)[span[0]:span[1]] if span else ""
        first, second = body.find(before), body.find(after)
        if first < 0 or second <= first:
            yield f"caption {label}: diagnostic must surround the measured call"
    source = sources.get(MEDIA, "")
    span = scope(source, ["fn caption_snapshot(&self,"])
    body = masked(source)[span[0]:span[1]] if span else ""
    if not span or "caption_at(" in body or "get_mut(" in body:
        yield "caption snapshot: observation must not mutate cue publication"


def run(g):
    sources = {}
    for path in sorted({row[1] for row in ROUTES}):
        try:
            sources[path] = (ROOT / path).read_text(encoding="utf-8")
        except OSError as exc:
            g.refuse(f"caption routes cannot read {path}: {exc}")
    g.counted("caption route files", sources, floor=4)
    g.counted("caption measured routes", ROUTES, floor=27)
    baseline = list(findings(sources)) + list(ordering_findings(sources))
    if baseline:
        for finding in baseline:
            g.finding(finding)
        g.refuse("caption baseline must pass before watched cuts")
    watched = 0
    for row in ROUTES:
        label, path, owners, needle = row
        source = sources[path]
        start, end = scope(source, owners)
        body = source[start:end]
        match = re.search(pattern(needle), masked(body))
        if match is None:
            g.refuse("caption mutation could not locate " + label)
        broken = g.doctor("caption " + label, body,
                          re.escape(body[match.start():match.end()]), "route_removed")
        changed = source[:start] + broken + source[end:]
        g.negative("caption " + label, lambda row=row, path=path, changed=changed:
                   findings({path: changed}, [row]), want="caption " + label + ":")
        watched += 1
    for label, path, owner, needle in (
        ("publish before send", GTK, ["fn caption_ask("], "core.occurrences.send(occ)"),
        ("callback before write", JAVA, ["void tracksApp(", "app.onCue(player, (t, text) -> {"], "t.write(cue, text)"),
        ("label after apply", GTK, ["fn apply(", "(NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {"], "label.set_text(&s)"),
    ):
        source = sources[path]
        start, end = scope(source, owner)
        body = source[start:end]
        changed = g.doctor("caption order " + label, body, re.escape(needle), "removed_call")
        changed_sources = {**sources, path: source[:start] + changed + source[end:]}
        g.negative("caption order " + label,
                   lambda changed_sources=changed_sources: ordering_findings(changed_sources),
                   want="caption " + label + ":")
        watched += 1
    source = sources[MEDIA]
    start, end = scope(source, ["fn caption_snapshot(&self,"])
    broken = g.doctor("caption mutating observer", source[start:end], r"^\{", "{ self.caption_at(player, 0);")
    g.negative("caption mutating observer",
               lambda: ordering_findings({**sources, MEDIA: source[:start] + broken + source[end:]}),
               want="observation must not mutate")
    watched += 1
    reader = next(row for row in ROUTES if row[0] == "read diagnostic")
    missing = g.doctor("caption missing reader", sources[GTK], re.escape("fn drawn_caption("), "fn removed_caption_reader(")
    g.negative("caption missing reader", lambda: findings({GTK: missing}, [reader]), want="missing or ambiguous owner")
    watched += 1
    g.negative("caption missing source", lambda: findings({}, [reader]), want="cannot read")
    watched += 1
    g.counted("caption watched negatives", watched, floor=len(ROUTES) + 6)

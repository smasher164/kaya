"""docs/media-player-plan.md M10; called by check-slider-commit."""

import re

ROWS = [
    # (backend, file, what, the text that must be there)
    ("SwiftUI mac", "swift/KayaSwiftUI.swift", "the surface's write waits while AppKit tracks",
     "if !slider.tracking { slider.doubleValue = node.value }"),
    ("SwiftUI mac", "swift/KayaSwiftUI.swift", "an unmoved gesture shows the held write",
     "if doubleValue == startValue, let node { doubleValue = node.value }"),
    ("SwiftUI mac", "swift/KayaSwiftUI.swift", "an unmoved gesture commits nothing",
     "if final && sender.tracking && sender.doubleValue == sender.startValue { return }"),
    ("SwiftUI iOS", "swift/KayaSwiftUI.swift", "the surface's write waits while UISlider tracks",
     "if !view.slider.isTracking { view.slider.setValue(Float(node.value), animated: false) }"),
    ("SwiftUI iOS", "swift/KayaSwiftUI.swift", "an unmoved gesture shows the held write and commits nothing",
     "sender.setValue(Float(node.value), animated: false)\n                return"),
    ("GTK", "crates/kaya/src/gtk.rs", "the write waits while the scale is dragged",
     "(NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) if slider.state.get().dragging => {"),
    ("GTK", "crates/kaya/src/gtk.rs", "the held write is kept",
     "state.pending = Some(v);"),
    ("GTK", "crates/kaya/src/gtk.rs", "the release shows what was held",
     "slider_show_pending(&committed, &quiet);"),
    ("GTK", "crates/kaya/src/gtk.rs", "a commit supersedes the held write",
     "state.committed = value;\n        state.pending = None;"),
    ("WinUI", "crates/kaya/src/winui/mod.rs", "the write waits while a pointer holds the slider",
     "if core.slider_cells.get(&id.0).is_some_and(|cell| winui_slider_held(core, slider, cell)) =>"),
    ("WinUI", "crates/kaya/src/winui/mod.rs", "the capture's loss shows what was held",
     "winui_slider_show_pending(&slider, &released, &released_quiet)?;"),
    ("WinUI", "crates/kaya/src/winui/mod.rs", "a commit supersedes the held write",
     "SliderCell::set(&cell.committed, v);\n        *cell.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;"),
    ("Compose", "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", "the slider draws the gesture's value",
     "value = kayaSliderShown(node).toFloat(),"),
    ("Compose", "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", "the raw pointer opens the gesture",
     "awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)"),
    ("Compose", "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", "an unmoved gesture commits nothing",
     "if (held && node.gestureValue == node.gestureStart) return"),
]

# THE CHARGE'S NEGATIVE, one per arm: the write applied at once, which every
# lane's scene reads as the thumb jumping under the pointer.
AT_ONCE = [
    ("SwiftUI mac", "swift/KayaSwiftUI.swift",
     "if !slider.tracking { slider.doubleValue = node.value }", "slider.doubleValue = node.value"),
    ("SwiftUI iOS", "swift/KayaSwiftUI.swift",
     "if !view.slider.isTracking { view.slider.setValue(Float(node.value), animated: false) }",
     "view.slider.setValue(Float(node.value), animated: false)"),
    ("GTK", "crates/kaya/src/gtk.rs",
     "(NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) if slider.state.get().dragging => {",
     "(NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) if false => {"),
    ("WinUI", "crates/kaya/src/winui/mod.rs",
     "if core.slider_cells.get(&id.0).is_some_and(|cell| winui_slider_held(core, slider, cell)) =>",
     "if false =>"),
    ("Compose", "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt",
     "value = kayaSliderShown(node).toFloat(),", "value = node.value.toFloat(),"),
]


def findings(texts, rows=ROWS):
    if len(rows) < 15:
        return ["the held-write census read fewer than 15 rows"]
    return [f"{rel}: the {backend} slider breaks the held write ({what}; docs/media-player-plan.md M10)"
            for backend, rel, what, text in rows if text not in texts[rel]]


def run(gate, read):
    texts = {rel: read(rel) for _, rel, _, _ in ROWS}
    for line in findings(texts):
        gate.finding(line)
    for backend, rel, now, at_once in AT_ONCE:
        cut = gate.doctor(f"the {backend} write applied at once", texts[rel], re.escape(now),
                          lambda _m, at_once=at_once: at_once)
        got = findings({**texts, rel: cut})
        if not any(backend in line for line in got):
            gate.finding(f"SELF-TEST: the {backend} write applied at once passed the held-write census")
        else:
            print(f"check-slider-commit: watched refusing: the {backend} write applied at once")
    withheld = findings(texts, ROWS[:-1])
    if withheld != ["the held-write census read fewer than 15 rows"]:
        gate.finding("SELF-TEST: the held-write census answered for a withheld row")
    print(f"check-slider-commit: held write read {len(ROWS)} rows across five arms, "
          f"{len(AT_ONCE)} at-once cuts")

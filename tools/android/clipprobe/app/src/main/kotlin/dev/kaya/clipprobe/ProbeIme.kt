package dev.kaya.clipprobe

import android.inputmethodservice.InputMethodService

// Deliberately empty. The IME's EXISTENCE is the point: as the default
// IME this package's clipboard reads are admitted before focus is ever
// checked (docs/clipboard-plan.md §7). The service never binds or
// shows — `adb shell ime set` is enough.
class ProbeIme : InputMethodService()

package dev.kaya.clipprobe

import android.inputmethodservice.InputMethodService

// Deliberately empty. The IME's existence is the whole point: when
// this package is the DEFAULT IME, ClipboardService's
// clipboardAccessAllowed admits the package's clipboard READS before
// it ever checks focus (isDefaultIme is consulted first), and the
// access notification is suppressed for the same reason. The service
// never needs to bind or show — `adb shell ime set` is enough.
class ProbeIme : InputMethodService()

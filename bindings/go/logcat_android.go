//go:build android

// A Go panic on Android reaches nobody (measured 2026-08-09;
// docs/go-mobile-plan.md §D3).
//
// It must stay a recover and not x/mobile's fd-2-into-a-pipe pump: the
// runtime calls exit(2) straight after writing the panic, with no
// guarantee the pump goroutine is scheduled in between.
package kaya

/*
#cgo LDFLAGS: -llog
#include <android/log.h>
#include <stdlib.h>

static void kaya_logcat_error(const char *tag, const char *msg) {
	__android_log_write(ANDROID_LOG_ERROR, tag, msg);
}
*/
import "C"

import (
	"fmt"
	"runtime/debug"
	"unsafe"
)

// logcatError writes one message under the tag the lane already reads
// (tools/android/run-emulator.py filters `kaya:*` and `Go:E`).
func logcatError(msg string) {
	tag := C.CString("kaya")
	text := C.CString(msg)
	C.kaya_logcat_error(tag, text)
	C.free(unsafe.Pointer(tag))
	C.free(unsafe.Pointer(text))
}

// androidReport logs a panic on one of kaya's two Android goroutines
// before the process goes. Must be deferred DIRECTLY, so its recover is
// the panicking frame's own; it re-raises.
func androidReport() {
	r := recover()
	if r == nil {
		return
	}
	logcatError(fmt.Sprintf("panic: %v\n\n%s", r, debug.Stack()))
	panic(r)
}

//go:build android

// WHAT A GO PANIC LOOKS LIKE ON ANDROID: nothing at all.
//
// MEASURED 2026-08-09 on emulator-5554, with a deliberately broken
// attach. The Go runtime prints a panic to file descriptor 2 and then
// exits; an Android app process has no stderr anyone reads, so the
// ENTIRE logcat of the crash was one line — "Process
// dev.kaya.milestone2go (pid 25418) has died: fg TOP" — and 290 lines
// of unrelated framework chatter. The panic's text, which named the
// cause and the fix, went to /dev/null.
//
// That is not a cosmetic problem. Every wall kaya's Go binding has on
// this platform is a panic, and until this file existed every one of
// them was silent where it matters most:
//
//   - "KAYA_SELFTEST is empty" — the run-time half of the environment
//     guard (docs/go-mobile-plan.md D2), the milestone's own defect;
//   - "already attached" — a configuration change re-running onCreate;
//   - "library speaks spec … this binding was generated from …" — the
//     stale-artifact guard, which the file above calls worth MORE on
//     Android than anywhere else;
//   - "the app's own main returned without serving" — the guard the
//     single-main entry point needs, added beside this file.
//
// A leg that hits one of those reads, on the lane, as "never printed a
// verdict". CLAUDE.md's invariant 3 is about exactly this shape: a
// guard nobody can see is barely a guard.
//
// THE FIX IS A RECOVER, NOT A PIPE, and the difference is a race.
// golang.org/x/mobile redirects fd 1 and 2 into an os.Pipe and pumps
// the reader into logcat on a goroutine
// (internal/mobileinit/mobileinit_android.go). That works for ordinary
// prints and NOT for the case that matters: a panic writes to fd 2 and
// the runtime calls exit(2) immediately after, with no guarantee the
// pump goroutine is ever scheduled in between. Recovering on the two
// goroutines kaya owns — the UI thread inside attach, and the app
// thread it starts — writes the message synchronously, before anything
// can exit, and then re-raises so the process still dies the way it
// should.
package kaya

/*
#cgo LDFLAGS: -llog
#include <android/log.h>
#include <stdlib.h>

// ANDROID_LOG_ERROR spelled through a wrapper rather than named from
// Go: the enum's value is stable ABI, but a wrapper is what keeps the
// constant's name in one place, and __android_log_write's own signature
// out of cgo's variadic rules.
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

// logcatError writes one message to the Android log under the tag the
// lane already reads (tools/android/run-emulator.sh filters `kaya:*`
// for verdicts and `Go:E` for crashes).
func logcatError(msg string) {
	tag := C.CString("kaya")
	text := C.CString(msg)
	C.kaya_logcat_error(tag, text)
	C.free(unsafe.Pointer(tag))
	C.free(unsafe.Pointer(text))
}

// androidReport makes a panic on one of kaya's two Android goroutines
// SAY SOMETHING before the process goes. Deferred directly, so its
// recover is the panicking frame's own; it re-raises, because a panic
// is fatal and this is about visibility, not about surviving.
//
// The stack is included because the two ends of an Android failure are
// far apart: the message names the rule, the stack names the guest
// function that broke it.
func androidReport() {
	r := recover()
	if r == nil {
		return
	}
	logcatError(fmt.Sprintf("panic: %v\n\n%s", r, debug.Stack()))
	panic(r)
}

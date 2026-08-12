// The presentation pump, for NEGATIVE TESTS ONLY.
//
// A binding's declare-time guards are not the binding's: they are the
// ROOT'S, and the root only sees a transaction when something resolves
// it through the scene. A headless guest queues records and exits, so
// every wall in crates/kaya/src/scene.rs — a role on a kind it does not
// fit, a negative window inset, a second brand accent — is unreachable
// from an ordinary `go test`. This package makes it reachable: submit,
// then play the pump for exactly one transaction and let the root
// answer.
//
// WHY IT LIVES UNDER internal/. Go refuses cgo in _test.go files
// outright ("use of cgo in test ... not supported"), so the C call
// cannot sit in the test that needs it; and it must not sit in the
// binding either, because a GUEST never pumps the presentation side —
// that is the interpreter's job, on the other end of the same C API.
// `internal` is the compiler-enforced version of that sentence: only
// dev.kaya/bindings/go and its own subtree may import this, so no
// guest, no scene and no app can reach it however hard they try.
package rootprobe

/*
#cgo CFLAGS: -I${SRCDIR}/../../../../crates/kaya/include
#include <kaya.h>
*/
import "C"

import "unsafe"

// Pump resolves ONE submitted transaction through the core's scene and
// returns the number of command bytes it produced.
//
// IT RETURNS ONLY WHEN THE ROOT ALLOWED THE TRANSACTION. A refusal is
// an assert inside the core, unwinding into an extern "C" frame, which
// aborts the process with the root's own sentence on stderr — nothing
// in Go can recover it, which is why the tests that use this run each
// case in a child process and read the corpse.
//
// It BLOCKS until a transaction arrives, and keeps blocking if the one
// it applied resolved to no commands at all (0 means shutdown to every
// pump, so the core never returns it for an empty batch). Callers mount
// something.
func Pump() int {
	// The pump's documented budget: at least 64 KiB, and an overflowing
	// batch fails loudly rather than truncating.
	buf := make([]byte, 64*1024)
	return int(C.kaya_next_commands(
		(*C.uint8_t)(unsafe.Pointer(&buf[0])), C.uintptr_t(len(buf))))
}

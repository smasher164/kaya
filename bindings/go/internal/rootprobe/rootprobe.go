// The presentation pump, FOR TESTS ONLY: submit a transaction, then
// play the pump for exactly one and let the root answer. Without it the
// walls in crates/kaya/src/scene.rs are unreachable from `go test`, and
// the apply records the BACKEND will get cannot be read at all.
//
// It lives under internal/ because Go refuses cgo in _test.go files
// ("use of cgo in test ... not supported") and because a guest must
// never pump the presentation side — that is the interpreter's job.
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
// IT RETURNS ONLY WHEN THE ROOT ALLOWED THE TRANSACTION. A refusal
// ENDS THE PROCESS — exit 1 with the root's own sentence on stderr
// (crates/kaya/src/fault.rs: unwatched processes die legibly; only a
// harness's watch turns a fault into a red leg) — and nothing in Go
// can recover it, so tests that use this run each case in a child
// process and read the corpse.
//
// It BLOCKS until a transaction arrives, and keeps blocking if the one
// it applied resolved to no commands (0 means shutdown to every pump).
// Callers mount something.
func Pump() int { return len(PumpBatch()) }

// PumpBatch is Pump with the bytes kept: the batch's apply records
// copied into Go memory.
//
// THE BLOB PAYLOADS ARE NOT IN HERE. A blob value in a record is a
// 1-based index into the batch's own table, which BlobData resolves and
// which the NEXT pump replaces — so read what you need before pumping
// again (the pump contract, kaya.h).
func PumpBatch() []byte {
	// The core sizes and owns the batch; the borrow dies at the next
	// pump, so copy now (the pump contract, kaya.h).
	var batch *C.uint8_t
	n := C.kaya_next_commands(&batch)
	if n == 0 || batch == nil {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(batch), C.int(n))
}

// BlobData fetches the bytes an apply record's blob value named, copied
// into Go memory. An unknown handle — or one from a superseded batch —
// reads as nil.
func BlobData(handle uint64) []byte {
	var n C.uintptr_t
	p := C.kaya_blob_data(C.uint64_t(handle), &n)
	if p == nil {
		return nil
	}
	// COPY, do not alias: the pointer borrows core memory that the next
	// pump frees for reuse.
	return C.GoBytes(unsafe.Pointer(p), C.int(n))
}

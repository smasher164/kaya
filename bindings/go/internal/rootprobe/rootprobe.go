// The presentation pump, FOR TESTS ONLY: submit a transaction, then
// play the pump for exactly one and let the root answer.
//
// It lives under internal/ because Go refuses cgo in _test.go files
// ("use of cgo in test ... not supported"); a guest must never pump the
// presentation side.
package rootprobe

/*
#cgo CFLAGS: -I${SRCDIR}/../../../../crates/kaya/include
#include <kaya.h>
*/
import "C"

import "unsafe"

// Pump resolves ONE submitted transaction through the core's scene and
// returns the number of command bytes it produced. A refusal ENDS THE
// PROCESS (crates/kaya/src/fault.rs) and Go cannot recover it, so tests
// run each case in a child process. It BLOCKS until a transaction
// arrives, and keeps blocking if the one it applied resolved to no
// commands — callers mount something.
func Pump() int { return len(PumpBatch()) }

// PumpBatch is Pump with the bytes kept: the batch's apply records copied
// into Go memory. THE BLOB PAYLOADS ARE NOT IN HERE — a blob value in a
// record is a 1-based index into the batch's own table, which BlobData
// resolves and which the NEXT pump replaces, so read what you need before
// pumping again (the pump contract, kaya.h).
func PumpBatch() []byte {
	// The borrow dies at the next pump, so copy now (the pump contract,
	// kaya.h).
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
	// COPY, do not alias: the next pump frees this for reuse.
	return C.GoBytes(unsafe.Pointer(p), C.int(n))
}

// Milestone 0 through the direct ring tier: Go reads the occurrence ring
// with its own atomics, using the record structs declared in kaya.h. cgo
// is crossed only to start the core, to wait on an empty ring, and to
// send commands. The data path is pure Go.
//
// Build the library first (cargo build / cargo xwin build --release),
// then:
//     KAYA_SELFTEST=1 go run crates/kaya/examples/milestone0.go
package main

/*
#cgo CFLAGS: -I${SRCDIR} -I${SRCDIR}/../include
#cgo darwin LDFLAGS: -L${SRCDIR}/../../../target/debug -lkaya -Wl,-rpath,${SRCDIR}/../../../target/debug
#cgo windows LDFLAGS: -L${SRCDIR} -L${SRCDIR}/../../../target/aarch64-pc-windows-msvc/release -lkaya
#include <kaya.h>
*/
import "C"

import (
	"fmt"
	"os"
	"runtime"
	"sync/atomic"
	"unsafe"
)

func init() {
	// kaya_run must own the process main thread.
	runtime.LockOSThread()
}

func setText(widget uint64, text string) {
	b := append([]byte(text), 0)
	C.kaya_set_text(C.uint64_t(widget), (*C.uint8_t)(unsafe.Pointer(&b[0])), C.size_t(len(text)))
}

func app(info C.KayaRingInfo) {
	head := (*uint32)(unsafe.Pointer(info.head))
	tail := (*uint32)(unsafe.Pointer(info.tail))
	data := uintptr(unsafe.Pointer(info.data))
	mask := uint32(info.capacity) - 1

	count := 0
	h := atomic.LoadUint32(head)
	for {
		t := atomic.LoadUint32(tail) // acquire: records below are visible
		if h == t {
			if !C.kaya_wait_occurrences() {
				return // shutdown
			}
			continue
		}
		header := (*C.KayaRecordHeader)(unsafe.Pointer(data + uintptr(h&mask)))
		if uint16(header.kind) == C.KAYA_OCCURRENCE_BUTTON_CLICKED {
			record := (*C.KayaRecordButtonClicked)(unsafe.Pointer(header))
			_ = record.widget_id
			count++
			noun := "time"
			if count != 1 {
				noun = "times"
			}
			setText(C.KAYA_WIDGET_LABEL, fmt.Sprintf("Clicked %d %s", count, noun))
		}
		h += uint32(header.size)
		atomic.StoreUint32(head, h) // release: hand the space back
	}
}

func main() {
	var info C.KayaRingInfo
	C.kaya_occurrence_ring(&info)
	done := make(chan struct{})
	go func() {
		app(info)
		close(done)
	}()
	code := int(C.kaya_run()) // takes over the main thread until the app exits
	<-done                    // shutdown has been signalled; the drain loop ends
	os.Exit(code)
}

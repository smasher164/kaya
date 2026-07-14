// Milestone 1 through the direct ring tier: Go reads the occurrence ring
// with its own atomics, using the record structs declared in kaya.h, and
// answers with packed transaction records through kaya_submit. The scene
// arrives as one transaction; the label's text is a signal binding this
// guest writes on every click. cgo is crossed only to start the core, to
// wait on an empty ring, and to submit.
//
// Build the library first (cargo build / cargo xwin build --release),
// then:
//     KAYA_SELFTEST=1 go run crates/kaya/examples/milestone0.go
package main

/*
#cgo CFLAGS: -I${SRCDIR} -I${SRCDIR}/../include
#cgo darwin LDFLAGS: -L${SRCDIR}/../../../target/debug -lkaya -Wl,-rpath,${SRCDIR}/../../../target/debug
#cgo windows LDFLAGS: -L${SRCDIR} -L${SRCDIR}/../../../target/aarch64-pc-windows-msvc/release -lkaya
#cgo linux LDFLAGS: -L${SRCDIR}/../../../target-linux/debug -lkaya -Wl,-rpath,${SRCDIR}/../../../target-linux/debug
#include <kaya.h>
*/
import "C"

import (
	"encoding/binary"
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

// Guest-allocated ids, counted from 1 per space.
const (
	sigText = 1
	wColumn = 1
	wButton = 2
	wLabel  = 3
)

// --- Transaction packing (KAYA_TX_* layouts from kaya.h) ---------------

type tx struct {
	bytes []byte
}

// record starts a record ({u32 size, u16 kind, u16 flags}; body follows)
// and returns its start for finish.
func (t *tx) record(kind uint16) int {
	start := len(t.bytes)
	t.bytes = append(t.bytes, 0, 0, 0, 0)
	t.bytes = binary.LittleEndian.AppendUint16(t.bytes, kind)
	t.bytes = append(t.bytes, 0, 0)
	return start
}

func (t *tx) u32(v uint32) { t.bytes = binary.LittleEndian.AppendUint32(t.bytes, v) }
func (t *tx) u64(v uint64) { t.bytes = binary.LittleEndian.AppendUint64(t.bytes, v) }

func (t *tx) str(s string) {
	t.u32(C.KAYA_VALUE_STR)
	t.u32(uint32(len(s)))
	t.bytes = append(t.bytes, s...)
}

func (t *tx) finish(start int) {
	for len(t.bytes)%8 != 0 {
		t.bytes = append(t.bytes, 0)
	}
	binary.LittleEndian.PutUint32(t.bytes[start:], uint32(len(t.bytes)-start))
}

func (t *tx) submit() {
	C.kaya_submit((*C.uint8_t)(unsafe.Pointer(&t.bytes[0])), C.size_t(len(t.bytes)))
}

func sceneTx() {
	var t tx
	s := t.record(C.KAYA_TX_CREATE_SIGNAL)
	t.u64(sigText)
	t.str("Clicked 0 times")
	t.finish(s)

	s = t.record(C.KAYA_TX_CREATE_WIDGET)
	t.u64(wColumn)
	t.u32(C.KAYA_KIND_COLUMN)
	t.u32(0)
	t.finish(s)

	s = t.record(C.KAYA_TX_CREATE_WIDGET)
	t.u64(wButton)
	t.u32(C.KAYA_KIND_BUTTON)
	t.u32(0)
	t.finish(s)

	s = t.record(C.KAYA_TX_SET_PROPERTY)
	t.u64(wButton)
	t.u32(C.KAYA_PROP_TEXT)
	t.u32(C.KAYA_SOURCE_CONST)
	t.str("Click me")
	t.finish(s)

	s = t.record(C.KAYA_TX_CREATE_WIDGET)
	t.u64(wLabel)
	t.u32(C.KAYA_KIND_LABEL)
	t.u32(0)
	t.finish(s)

	s = t.record(C.KAYA_TX_SET_PROPERTY)
	t.u64(wLabel)
	t.u32(C.KAYA_PROP_TEXT)
	t.u32(C.KAYA_SOURCE_SIGNAL)
	t.u64(sigText)
	t.finish(s)

	s = t.record(C.KAYA_TX_ADD_CHILD)
	t.u64(wColumn)
	t.u64(wButton)
	t.finish(s)

	s = t.record(C.KAYA_TX_ADD_CHILD)
	t.u64(wColumn)
	t.u64(wLabel)
	t.finish(s)

	s = t.record(C.KAYA_TX_MOUNT)
	t.u64(0) // window 0: the default
	t.u64(wColumn)
	t.finish(s)

	t.submit()
}

func writeTx(text string) {
	var t tx
	s := t.record(C.KAYA_TX_WRITE_SIGNAL)
	t.u64(sigText)
	t.str(text)
	t.finish(s)
	t.submit()
}

func app(info C.KayaRingInfo) {
	head := (*uint32)(unsafe.Pointer(info.head))
	tail := (*uint32)(unsafe.Pointer(info.tail))
	data := uintptr(unsafe.Pointer(info.data))
	mask := uint32(info.capacity) - 1

	sceneTx()

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
			writeTx(fmt.Sprintf("Clicked %d %s", count, noun))
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

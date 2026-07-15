// The milestone-2 scene through the direct ring tier: Go reads the
// occurrence ring with its own atomics and answers with packed
// transaction records through kaya_submit. The scene declares a When
// (the extras banner) and a nested For (groups holding items); clicks on
// stamped remove buttons come back as a template node id plus key path,
// and the app answers by removing that entry. cgo is crossed only to
// start the core, to wait on an empty ring, and to submit.
//
// Build the library first (cargo build / cargo xwin build --release),
// then:
//     KAYA_SELFTEST=1 go run crates/kaya/examples/milestone2.go
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
	sigStatus = 1
	sigExtras = 2
	wColumn   = 1
	wStep     = 2
	wStatus   = 3
	wWhen     = 4
	wGroups   = 5
	cGroups   = 1
	cItems    = 2
	nBanner   = 1
	nGroupCol = 2
	nGroupLbl = 3
	nItemsFor = 4
	nItemRow  = 5
	nItemText = 6
	nRemove   = 7
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

func (t *tx) pad() {
	for len(t.bytes)%8 != 0 {
		t.bytes = append(t.bytes, 0)
	}
}

// Values are self-padded to 8: they concatenate inside record bodies.
func (t *tx) str(s string) {
	t.u32(C.KAYA_VALUE_STR)
	t.u32(uint32(len(s)))
	t.bytes = append(t.bytes, s...)
	t.pad()
}

func (t *tx) boolean(v bool) {
	t.u32(C.KAYA_VALUE_BOOL)
	t.u32(1)
	b := byte(0)
	if v {
		b = 1
	}
	t.bytes = append(t.bytes, b)
	t.pad()
}

// A key path: {u32 count, u32 reserved, count values}.
func (t *tx) path(keys ...string) {
	t.u32(uint32(len(keys)))
	t.u32(0)
	for _, k := range keys {
		t.str(k)
	}
}

func (t *tx) finish(start int) {
	t.pad()
	binary.LittleEndian.PutUint32(t.bytes[start:], uint32(len(t.bytes)-start))
}

func (t *tx) submit() {
	C.kaya_submit((*C.uint8_t)(unsafe.Pointer(&t.bytes[0])), C.size_t(len(t.bytes)))
}

func (t *tx) widget(id uint64, kind uint32) {
	s := t.record(C.KAYA_TX_CREATE_WIDGET)
	t.u64(id)
	t.u32(kind)
	t.u32(0)
	t.finish(s)
}

func (t *tx) textConst(id uint64, text string) {
	s := t.record(C.KAYA_TX_SET_PROPERTY)
	t.u64(id)
	t.u32(C.KAYA_PROP_TEXT)
	t.u32(C.KAYA_SOURCE_CONST)
	t.str(text)
	t.finish(s)
}

func (t *tx) textElement(id uint64, level uint32) {
	s := t.record(C.KAYA_TX_SET_PROPERTY)
	t.u64(id)
	t.u32(C.KAYA_PROP_TEXT)
	t.u32(C.KAYA_SOURCE_ELEMENT)
	t.u32(level)
	t.u32(0)
	t.finish(s)
}

func (t *tx) twoU64(kind uint16, a, b uint64) {
	s := t.record(kind)
	t.u64(a)
	t.u64(b)
	t.finish(s)
}

func (t *tx) collection(id uint64) {
	s := t.record(C.KAYA_TX_CREATE_COLLECTION)
	t.u64(id)
	t.finish(s)
}

func (t *tx) templateEnd() {
	s := t.record(C.KAYA_TX_TEMPLATE_END)
	t.finish(s)
}

func (t *tx) insert(coll uint64, at []string, key, value string) {
	s := t.record(C.KAYA_TX_COLLECTION_INSERT)
	t.u64(coll)
	t.path(at...)
	t.str(key)
	t.str(value)
	t.finish(s)
}

func (t *tx) update(coll uint64, at []string, key, value string) {
	s := t.record(C.KAYA_TX_COLLECTION_UPDATE)
	t.u64(coll)
	t.path(at...)
	t.str(key)
	t.str(value)
	t.finish(s)
}

func (t *tx) remove(coll uint64, at []string, key string) {
	s := t.record(C.KAYA_TX_COLLECTION_REMOVE)
	t.u64(coll)
	t.path(at...)
	t.str(key)
	t.finish(s)
}

func (t *tx) writeStr(sig uint64, text string) {
	s := t.record(C.KAYA_TX_WRITE_SIGNAL)
	t.u64(sig)
	t.str(text)
	t.finish(s)
}

func (t *tx) writeBool(sig uint64, v bool) {
	s := t.record(C.KAYA_TX_WRITE_SIGNAL)
	t.u64(sig)
	t.boolean(v)
	t.finish(s)
}

func sceneTx() {
	var t tx
	s := t.record(C.KAYA_TX_CREATE_SIGNAL)
	t.u64(sigStatus)
	t.str("step 0")
	t.finish(s)
	s = t.record(C.KAYA_TX_CREATE_SIGNAL)
	t.u64(sigExtras)
	t.boolean(false)
	t.finish(s)

	t.widget(wColumn, C.KAYA_KIND_COLUMN)
	t.widget(wStep, C.KAYA_KIND_BUTTON)
	t.textConst(wStep, "step")
	t.widget(wStatus, C.KAYA_KIND_LABEL)
	s = t.record(C.KAYA_TX_SET_PROPERTY)
	t.u64(wStatus)
	t.u32(C.KAYA_PROP_TEXT)
	t.u32(C.KAYA_SOURCE_SIGNAL)
	t.u64(sigStatus)
	t.finish(s)

	// When(extras): a banner label. The scope brackets the blueprint.
	t.twoU64(C.KAYA_TX_CREATE_WHEN, wWhen, sigExtras)
	t.widget(nBanner, C.KAYA_KIND_LABEL)
	t.textConst(nBanner, "extras on")
	t.templateEnd()

	// For over groups, nesting a For over items.
	t.collection(cGroups)
	t.twoU64(C.KAYA_TX_CREATE_FOR, wGroups, cGroups)
	t.widget(nGroupCol, C.KAYA_KIND_COLUMN)
	t.widget(nGroupLbl, C.KAYA_KIND_LABEL)
	t.textElement(nGroupLbl, 0)
	t.twoU64(C.KAYA_TX_ADD_CHILD, nGroupCol, nGroupLbl)
	t.collection(cItems)
	t.twoU64(C.KAYA_TX_CREATE_FOR, nItemsFor, cItems)
	t.widget(nItemRow, C.KAYA_KIND_COLUMN)
	t.widget(nItemText, C.KAYA_KIND_LABEL)
	t.textElement(nItemText, 0)
	t.widget(nRemove, C.KAYA_KIND_BUTTON)
	t.textConst(nRemove, "remove")
	t.twoU64(C.KAYA_TX_ADD_CHILD, nItemRow, nItemText)
	t.twoU64(C.KAYA_TX_ADD_CHILD, nItemRow, nRemove)
	t.templateEnd()
	t.twoU64(C.KAYA_TX_ADD_CHILD, nGroupCol, nItemsFor)
	t.templateEnd()

	t.twoU64(C.KAYA_TX_ADD_CHILD, wColumn, wStep)
	t.twoU64(C.KAYA_TX_ADD_CHILD, wColumn, wStatus)
	t.twoU64(C.KAYA_TX_ADD_CHILD, wColumn, wWhen)
	t.twoU64(C.KAYA_TX_ADD_CHILD, wColumn, wGroups)
	t.twoU64(C.KAYA_TX_MOUNT, 0, wColumn) // window 0: the default

	t.submit()
}

// One click record's body: u64 id, u32 path_len, u32 pad, then values.
func parseClick(rec []byte) (id uint64, keys []string) {
	id = binary.LittleEndian.Uint64(rec[8:])
	pathLen := binary.LittleEndian.Uint32(rec[16:])
	at := 24
	for i := uint32(0); i < pathLen; i++ {
		vlen := int(binary.LittleEndian.Uint32(rec[at+4:]))
		keys = append(keys, string(rec[at+8:at+8+vlen]))
		at += 8 + (vlen+7)&^7
	}
	return
}

func app(info C.KayaRingInfo) {
	head := (*uint32)(unsafe.Pointer(info.head))
	tail := (*uint32)(unsafe.Pointer(info.tail))
	data := uintptr(unsafe.Pointer(info.data))
	mask := uint32(info.capacity) - 1

	sceneTx()

	steps := 0
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
		size := uint32(header.size)
		if uint16(header.kind) == C.KAYA_OCCURRENCE_BUTTON_CLICKED {
			rec := unsafe.Slice((*byte)(unsafe.Pointer(data+uintptr(h&mask))), size)
			id, keys := parseClick(rec)
			if len(keys) == 0 && id == wStep {
				steps++
				var tx tx
				switch steps {
				case 1:
					tx.insert(cGroups, nil, "g1", "Work")
					tx.insert(cItems, []string{"g1"}, "a", "send report")
					tx.insert(cItems, []string{"g1"}, "b", "buy milk")
				case 2:
					tx.insert(cGroups, nil, "g2", "Home")
					tx.insert(cItems, []string{"g2"}, "a", "water plants")
					tx.update(cGroups, nil, "g1", "Office")
				}
				tx.writeBool(sigExtras, steps == 1)
				tx.writeStr(sigStatus, fmt.Sprintf("step %d", steps))
				tx.submit()
			} else if len(keys) == 2 && id == nRemove {
				var tx tx
				tx.remove(cItems, keys[:1], keys[1])
				tx.writeStr(sigStatus, fmt.Sprintf("removed %s/%s", keys[0], keys[1]))
				tx.submit()
			}
		}
		h += size
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

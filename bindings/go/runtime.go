// kaya runtime for Go guests: cgo, loading, the direct-ring occurrence
// loop, and submit. Hand-written; kaya_wire.go beside it is generated,
// and the ring's consumer contract is the io_uring recipe in kaya.h.
// THE #cgo NEGATIONS BELOW ARE LOAD-BEARING, and the ios line must name
// the archive BY PATH (docs/traps.md: a Go #cgo darwin line links iOS
// against the macOS libkaya).
package kaya

/*
#cgo CFLAGS: -I${SRCDIR}/../../crates/kaya/include -I${SRCDIR}/../.. -I${SRCDIR}
#cgo darwin,!ios LDFLAGS: -L${SRCDIR}/../../target/debug -lkaya -Wl,-rpath,${SRCDIR}/../../target/debug
#cgo ios LDFLAGS: ${SRCDIR}/../../target/aarch64-apple-ios-sim/debug/libkaya.a -framework UIKit -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework QuartzCore
#cgo windows LDFLAGS: -L${SRCDIR}/../.. -L${SRCDIR}/../../target/aarch64-pc-windows-msvc/release -lkaya
#cgo linux,!android LDFLAGS: -L${SRCDIR}/../../target-linux/debug -lkaya -Wl,-rpath,${SRCDIR}/../../target-linux/debug
#cgo android LDFLAGS: -L${SRCDIR}/../../target/aarch64-linux-android/debug -lkaya
#include <kaya.h>
#include <stdint.h>
#ifdef _WIN32
// Declared rather than included: kernel32 is linked into every process
// and <windows.h> would pull a world in behind it. DWORD is unsigned
// long, so this declaration is the one in winbase.h.
unsigned long __stdcall GetCurrentThreadId(void);
static uint64_t kaya_go_thread_id(void) { return (uint64_t)GetCurrentThreadId(); }
#else
#include <pthread.h>
static uint64_t kaya_go_thread_id(void) { return (uint64_t)(uintptr_t)pthread_self(); }
#endif
*/
import "C"

import (
	"bytes"
	"fmt"
	"os"
	"runtime"
	"sync/atomic"
	"unsafe"
)

// hostedEntry is true where the OPERATING SYSTEM owns the process entry
// and hands kaya a thread: Android and nothing else, where kaya_run is a
// hard panic (crates/kaya/src/capi.rs). A CONSTANT, NOT A VARIABLE:
// runtime.GOOS is itself a constant, so the compiler keeps one arm and
// drops the other while the type checker sees both on every platform.
const hostedEntry = runtime.GOOS == "android"

// THE APP THREAD IS CLAIMED BY THE BINDING, NOT BY THE GUEST: the core
// must own the process main thread wherever there is one, and a package
// init is the earliest moment the lock can be taken. NOT ON ANDROID —
// package inits there run on a goroutine that EXITS when initialization
// finishes and would take the locked thread with it; the attach entry
// locks the app thread instead (bindings/go/android.go).
func init() {
	if !hostedEntry {
		runtime.LockOSThread()
	}
}

// The app goroutine's OS thread, claimed at Serve and read at every
// transaction gate (requireAppThread, app.go). Zero until the dispatch
// loop starts, which is what lets the guest's first Build run on the
// main goroutine — Python's `_app_thread = None` arm, same rule.
var appThread atomic.Uint64

// claimAppThread pins the calling goroutine to its OS thread and records
// that thread as the app's. THE THREAD IS THE GOROUTINE HERE, and only
// because of the lock: Go exposes no goroutine id, but a locked thread
// runs no other goroutine, so "same OS thread" answers "same goroutine"
// exactly. The measurement that chose it: docs/deferred.md, the handle
// bindings' thread check.
func claimAppThread() {
	runtime.LockOSThread()
	appThread.Store(uint64(C.kaya_go_thread_id()))
}

func threadID() uint64 { return uint64(C.kaya_go_thread_id()) }

var ring C.KayaRingInfo

// Init fetches the ring layout. Call once, before the occurrence loop.
func Init() {
	C.kaya_occurrence_ring(&ring)
}

// Env reads one environment variable AS THE HOST PROCESS SEES IT, and is
// the only spelling a kaya guest may use. Empty when unset; LookupEnv
// adds the found bit. os.Getenv is SILENTLY WRONG on Android, reading ""
// where C.getenv("KAYA_SELFTEST") reads the scene name (docs/traps.md:
// os.Getenv is empty forever in a c-shared library). tools/check-go-env.py
// bans it and doctors BOTH C.getenv sites here, so the spelling stays.
func Env(name string) string {
	value, _ := LookupEnv(name)
	return value
}

// LookupEnv is Env with the found bit. Same C view, same reason.
func LookupEnv(name string) (string, bool) {
	key := C.CString(name)
	defer C.free(unsafe.Pointer(key))
	// getenv returns a pointer INTO the host's environ, live and
	// borrowed; GoString copies before anything can rewrite it.
	value := C.getenv(key)
	if value == nil {
		return "", false
	}
	return C.GoString(value), true
}

// The host capability word, taken from the HEADER rather than written
// again here, so a renumbering reaches Go with no edit.
const capAuxWindows = uint64(C.KAYA_CAP_AUX_WINDOWS)

// The core's own number, not a copy (check-file-modes' trap class).
const sortNoneValue = uint32(C.KAYA_SORT_NONE)

func capabilityBits() uint64 { return uint64(C.kaya_capabilities()) }

// The stale-artifact guard, run once before the core takes the thread:
// this binding was generated from one spec revision; the loaded library
// must speak the same one.
func checkSpec() {
	if got := uint64(C.kaya_spec_hash()); got != SpecHash {
		panic(fmt.Sprintf(
			"kaya: library speaks spec %#016x, this binding was generated from %#016x — rebuild the library or regenerate bindings",
			got, SpecHash))
	}
}

// Run enters the core on the calling thread and returns the exit code
// when the app ends. THE THREAD MUST BE THE PROCESS MAIN THREAD, which
// the binding's init above arranges on every host that has one.
//
// A GUEST CALLS App.Run, NOT THIS: this is the desktop half of App.Run's
// body. On Android it panics inside the core.
func Run() int {
	checkSpec()
	return int(C.kaya_run())
}

// Submit sends one transaction: the concatenation of packed records
// (Tx* results), applied atomically.
func Submit(records ...[]byte) {
	var tx []byte
	for _, r := range records {
		tx = append(tx, r...)
	}
	C.kaya_submit((*C.uint8_t)(unsafe.Pointer(&tx[0])), C.size_t(len(tx)))
}

// RegisterBlob registers bulk payload bytes with the core: one copy into
// core-owned memory, returning the u64 handle the next submit consumes
// (referenced or not). The caller's bytes may be dropped on return.
func RegisterBlob(data []byte) uint64 {
	if len(data) == 0 {
		// &data[0] does not exist for an empty slice; a one-byte
		// stand-in with length 0 keeps the C side off a null pointer.
		var zero C.uint8_t
		return uint64(C.kaya_blob_register(&zero, 0))
	}
	return uint64(C.kaya_blob_register((*C.uint8_t)(unsafe.Pointer(&data[0])), C.size_t(len(data))))
}

// occurrenceBlob redeems an occurrence blob for its bytes, and releases
// it. Called by the generated decoder, never by a guest.
//
// COPY THEN RELEASE, in that order: the pointer borrows core memory that
// the release frees. An occurrence blob's table has no boundary that
// retires a handle, so the decoder must let go of it while decoding.
func occurrenceBlob(handle uint64) []byte {
	var length C.size_t
	data := C.kaya_occurrence_blob(C.uint64_t(handle), &length)
	var out []byte
	if data != nil && length > 0 {
		out = C.GoBytes(unsafe.Pointer(data), C.int(length))
	}
	C.kaya_occurrence_blob_release(C.uint64_t(handle))
	return out
}

// PollOccurrence reads the next occurrence if one is ready and NEVER
// blocks; ready is false when the ring is empty right now. keys is nil
// when id is a widget id, else id is a template node id and keys is the
// stamped copy's key path, outermost first. Separate from
// WaitOccurrences because the app goroutine has a SECOND source of work
// (posted closures) and a single blocking read would park inside C.
func PollOccurrence() (kind uint16, id uint64, keys []any, payload any, ready bool) {
	head := (*uint32)(unsafe.Pointer(ring.head))
	tail := (*uint32)(unsafe.Pointer(ring.tail))
	data := uintptr(unsafe.Pointer(ring.data))
	mask := uint32(ring.capacity) - 1

	h := atomic.LoadUint32(head)
	for {
		t := atomic.LoadUint32(tail) // acquire: records below are visible
		if h == t {
			return 0, 0, nil, nil, false
		}
		at := data + uintptr(h&mask)
		size := *(*uint32)(unsafe.Pointer(at))
		rec := unsafe.Slice((*byte)(unsafe.Pointer(at)), size)
		kind, id, keys, payload, valid := ParseOccurrence(rec)
		h += size
		atomic.StoreUint32(head, h) // release: hand the space back
		if valid {
			return kind, id, keys, payload, true
		}
		// A pad or an unparsable record: consume it and keep looking.
	}
}

// WaitOccurrences blocks until there MAY be something to do: a record
// arrived, or another goroutine called Wake. Returns false once the core
// has shut down and the ring is drained. "May" is honest — a wake
// returns true with the ring still empty, so the caller re-checks both
// sources rather than trusting the return.
func WaitOccurrences() bool {
	return bool(C.kaya_wait_occurrences())
}

// Wake returns the app goroutine from WaitOccurrences. Safe from any
// goroutine; the binding calls it from Post.
func Wake() {
	C.kaya_wake()
}

// Asset is one open asset: the bytes of a file the app's own BUILD
// shipped, held by the core and named the same way on five platforms
// (docs/assets-plan.md). Redeem it into kaya (FontAsset,
// AppIdentityAsset — the bytes never enter Go) or read it yourself
// (Bytes, Reader); there is NO FILE DESCRIPTOR here. Close is
// idempotent and a cleanup releases one a guest forgot.
type Asset struct {
	handle uint64
	name   string
}

// openAsset is Tx.Asset's floor: the handle, or 0 for a miss. The
// sentence for a miss is assetMissSentence's, and the raise is app.go's.
func openAsset(name string) *Asset {
	raw := []byte(name)
	var handle C.uint64_t
	if len(raw) == 0 {
		// &raw[0] does not exist for an empty slice, and an empty name
		// must still reach the core — it has a sentence for it.
		var zero C.uint8_t
		handle = C.kaya_asset_open(&zero, 0)
	} else {
		handle = C.kaya_asset_open((*C.uint8_t)(unsafe.Pointer(&raw[0])), C.size_t(len(raw)))
	}
	if handle == 0 {
		return nil
	}
	asset := &Asset{handle: uint64(handle), name: name}
	// The cleanup captures the HANDLE by value and never the Asset: one
	// closing over the object would keep it reachable forever and never
	// run. Release is idempotent.
	runtime.AddCleanup(asset, func(handle uint64) {
		C.kaya_asset_release(C.uint64_t(handle))
	}, asset.handle)
	return asset
}

// assetMissSentence CARRIES the core's sentence for why an open would
// fail — empty when it would succeed. ASKED TWICE ON PURPOSE: the first
// call learns the length, the second fills a buffer of exactly that size
// (a fixed one truncates the END, where the census lives). NOT named
// `assetWhyNot`: tools/check-diagnostics.py reads any *WhyNot by name,
// and `asset_why_not` in crates/kaya/src/assets.rs earned it.
func assetMissSentence(name string) string {
	raw := []byte(name)
	var (
		namePtr *C.uint8_t
		zero    C.uint8_t
	)
	if len(raw) == 0 {
		namePtr = &zero
	} else {
		namePtr = (*C.uint8_t)(unsafe.Pointer(&raw[0]))
	}
	needed := int(C.kaya_asset_why_not(namePtr, C.size_t(len(raw)), nil, 0))
	if needed == 0 {
		return ""
	}
	out := make([]byte, needed)
	written := int(C.kaya_asset_why_not(namePtr, C.size_t(len(raw)),
		(*C.uint8_t)(unsafe.Pointer(&out[0])), C.size_t(needed)))
	return string(out[:min(written, needed)])
}

// Name is what Tx.Asset was given, not a path: there is no path to hand
// back on Android at all, so no binding offers one.
func (a *Asset) Name() string { return a.name }

// Bytes copies the asset's bytes out of core memory. The copy is not
// avoidable: a Go slice aliasing the C pointer would outlive the
// release.
func (a *Asset) Bytes() []byte {
	a.alive("Bytes")
	var length C.size_t
	data := C.kaya_asset_bytes(C.uint64_t(a.handle), &length)
	var out []byte
	if data != nil && length > 0 {
		out = C.GoBytes(unsafe.Pointer(data), C.int(length))
	}
	// The cleanup releases the handle the moment this Asset is
	// unreachable, which can happen while a method that no longer touches
	// the receiver is still running. KeepAlive holds it past the C call.
	runtime.KeepAlive(a)
	return out
}

// Reader is the asset as an io.Reader/io.Seeker: a *bytes.Reader over a
// copy of the bytes. Entirely Go's.
func (a *Asset) Reader() *bytes.Reader { return bytes.NewReader(a.Bytes()) }

// Len is the asset's byte count. Never 0 for a live asset: the core
// refuses a zero-byte asset at the open, since an empty blob sails
// through every lowering.
func (a *Asset) Len() int {
	a.alive("Len")
	n := int(C.kaya_asset_len(C.uint64_t(a.handle)))
	runtime.KeepAlive(a)
	return n
}

// Close releases the core's handle. Idempotent, and safe to defer
// beside the open.
func (a *Asset) Close() {
	handle := a.handle
	a.handle = 0
	if handle != 0 {
		C.kaya_asset_release(C.uint64_t(handle))
	}
	runtime.KeepAlive(a)
}

// blobHandle registers the core's own bytes into the pending table and
// answers the handle the next submit consumes; the bytes never enter Go.
// Unexported: FontAsset, AppIdentityAsset and ImageAsset are the whole
// offer.
func (a *Asset) blobHandle() uint64 {
	a.alive("a blob redemption")
	handle := uint64(C.kaya_asset_blob(C.uint64_t(a.handle)))
	runtime.KeepAlive(a)
	return handle
}

// alive is the asset's one panic, shared by every method that reads the
// handle so they cannot drift in what they say.
func (a *Asset) alive(what string) {
	if a == nil || a.handle == 0 {
		name := ""
		if a != nil {
			name = a.name
		}
		panic(fmt.Sprintf("kaya: %s on a closed asset (%q) — the handle was "+
			"released, and the bytes it borrowed are the core's. Read before "+
			"Close, or keep the bytes rather than the asset.", what, name))
	}
}

// PickedFile is one file the picker answered with. LocalPath is a
// RE-OPENABLE NAME, empty unless re-opening actually works — the three
// desktops and neither phone (DESIGN.md, File dialogs).
type PickedFile struct {
	Handle    uint64
	Name      string
	LocalPath string
}

// Open redeems the handle for a real *os.File, plus whether it seeks
// (an Android provider may hand back a pipe). It BLOCKS, possibly for a
// long time — a cloud provider may download first — so call it off the
// app goroutine and post the result back. THE FILE BECOMES GO'S:
// os.NewFile takes the descriptor, or on Windows the HANDLE, over. A
// SAVE DESTINATION OPENS EMPTY (DESIGN.md, File dialogs; save-plan D1).
func (f PickedFile) Open(mode uint32) (file *os.File, seekable bool, err error) {
	var raw C.int64_t
	var seeks C.uint32_t
	rc := C.kaya_open_picked(C.uint64_t(f.Handle), C.uint32_t(mode), &raw, &seeks)
	if rc != 0 {
		return nil, false, fmt.Errorf("kaya: opening the picked file failed (code %d)", int(rc))
	}
	return os.NewFile(uintptr(raw), f.Name), seeks != 0, nil
}

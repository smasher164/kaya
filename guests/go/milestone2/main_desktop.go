//go:build !android

// The desktop and iOS tail: the guest OWNS the process main thread and
// lends it to kaya. `!android` rather than a list of the platforms that
// have a main, because that is the real rule — Android is the one host
// where the OS owns the entry (Zygote forks the process, ActivityThread
// owns the Looper) and kaya_run is a hard panic. GOOS=ios reaches this
// file, which is what makes the iOS lane's `-buildmode=exe` guests the
// same shape as the desktops'.

package main

import (
	"os"
	"runtime"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

func main() {
	os.Exit(milestone2().Run())
}

// The accessibility conformance scene from Go: the two universal props
// (A11yID, A11yLabel) and the verb that reads them back out of the
// PLATFORM'S OWN accessibility tree rather than kaya's model.
//
// Every widget kind appears, and exactly one container of each
// container kind — the props are universal, and container targets are
// stable only while a scene keeps one of each. See guests/rust/a11y.rs
// for the full note; the byte-frozen contract is
// tools/scenes/a11y.steps.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

// A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the gallery
// scene's asset, embedded as source per the include_str! doctrine —
// scenes carry their inputs, no runtime file I/O.
var testPNG = []byte{
	137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
	0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0,
	0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0,
	194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0,
	0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
}

func main() {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Mount(tx.Column(func() {
			// Caption-bearing controls: identified, but deliberately
			// NOT labelled. The platform must speak the caption.
			tx.Button("Save", nil).A11yID("save").A11yHint("save the draft")
			tx.Checkbox("Details", nil).A11yID("details").A11yHint("show more detail")
			tx.Button("Reset", nil).A11yID("reset")
			tx.LabelText("Ready").A11yID("status")
			// Caption-less controls: an app MUST name these, and the
			// tree must report the authored name.
			tx.Entry(nil).A11yID("name").A11yLabel("Full name")
			tx.Textarea(nil).A11yID("notes").A11yLabel("Notes")
			tx.Slider(0.0, 1.0, 0.5, nil).A11yID("volume").A11yLabel("Volume")
			tx.Progress(0.25).A11yID("loading").A11yLabel("Loading")
			tx.Image(testPNG).A11yID("logo").A11yLabel("Logo")
			// The two CHOICE kinds: their options carry captions, the
			// choice itself does not.
			tx.Select([]string{"Red", "Green"}, 0, nil).
				A11yID("color").A11yLabel("Color")
			tx.Radio([]string{"Small", "Large"}, 0, nil).
				A11yID("size").A11yLabel("Size")
			// Containers are GROUPS to an assistive client, and naming
			// one is how an app declares it a group.
			tx.Grid(2, func() {
				tx.LabelText("Name")
				tx.LabelText("Ada")
			}).A11yID("cells").A11yLabel("Cells")
			tx.Scroll(func() {
				tx.LabelText("Item")
			}).A11yID("feed").A11yLabel("Feed")
			tx.Row(func() {
				tx.Button("Cancel", nil).A11yID("cancel")
				tx.Button("OK", nil).A11yID("ok")
			}).A11yID("actions").A11yLabel("Actions")
		}).A11yID("form").A11yLabel("Form"))
	})

	os.Exit(app.Run())
}

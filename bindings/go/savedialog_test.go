package kaya

// The save request's two binding-tier facts, pinned where a lane already
// walks: tools/check-abort.sh runs `go test dev.kaya/bindings/go` on
// every desktop lane, so these run with no GUI, no panel and no mac.
//
// WHY A TEST RATHER THAN THE SCENE. The save scene proves both of these
// on macOS through a real NSSavePanel — but only there, only when a
// human's box has a logged-in GUI session, and at nine seconds a panel.
// The narrowing below is the contract rule with the widest blast radius
// ("cancel is the empty answer, and a guest must remember NOTHING for
// it", docs/save-plan.md D2): a save dialog that answered cancel with a
// destination would have an app write a file the user declined to name.

import "testing"

// CANCEL IS NIL, AND A DESTINATION IS THE FIRST LOCATOR. The wire says
// "exactly one locator or none" and the picker's result record carries a
// LIST, so somebody has to narrow it; SaveDialogRef.Show does, once, for
// every app.
func TestSaveDialogNarrowsToOneOrNone(t *testing.T) {
	app := NewApp()
	var dialog uint64
	var seen []*PickedFile
	app.Build(func(tx *Tx) {
		dialog = tx.SaveFile("copy").OnResult(func(tx *Tx, file *PickedFile) {
			seen = append(seen, file)
		}).Show()
	})

	deliver := app.fileDialogs[dialog]
	if deliver == nil {
		t.Fatal("Show registered no handler for the save request — the one answer would arrive nowhere")
	}

	// The empty answer: cancel.
	app.Build(func(tx *Tx) { deliver(tx, nil) })
	// One locator: the destination.
	app.Build(func(tx *Tx) {
		deliver(tx, []PickedFile{{Handle: 7, Name: "final", LocalPath: "/tmp/final"}})
	})

	if len(seen) != 2 {
		t.Fatalf("the handler ran %d time(s), wanted 2", len(seen))
	}
	if seen[0] != nil {
		t.Errorf("cancel arrived as %+v, wanted nil — an app would remember a destination the user declined to name", *seen[0])
	}
	if seen[1] == nil {
		t.Fatal("a destination arrived as nil — the save would go nowhere")
	}
	if seen[1].Handle != 7 || seen[1].Name != "final" {
		t.Errorf("the destination is %+v, wanted handle 7 named \"final\"", *seen[1])
	}
}

// ONE ID SPACE AND ONE LIVE SLOT, whichever dialog asked. The core keeps
// a single live-dialog slot and answers both kinds on file_dialog_result,
// so a save request drawing from a counter of its own would collide with
// a picker id and steer one dialog's answer into the other's handler.
func TestSaveDialogSharesThePickerIdSpace(t *testing.T) {
	app := NewApp()
	var pick, save, next uint64
	app.Build(func(tx *Tx) {
		pick = tx.PickFile().OnResult(func(*Tx, []PickedFile) {}).Show()
		save = tx.SaveFile("copy").OnResult(func(*Tx, *PickedFile) {}).Show()
		next = tx.PickFiles().OnResult(func(*Tx, []PickedFile) {}).Show()
	})
	if save != pick+1 || next != save+1 {
		t.Errorf("ids ran %d, %d, %d — a save request must take the next id in the picker's own space", pick, save, next)
	}
	if len(app.fileDialogs) != 3 {
		t.Errorf("%d registrations for 3 requests — both dialog kinds answer out of one table", len(app.fileDialogs))
	}
}

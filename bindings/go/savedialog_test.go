package kaya

// The save scene proves both of these on macOS through a real NSSavePanel,
// but only there and only with a logged-in GUI session; the narrowing rule is
// docs/save-plan.md D2.

import "testing"

// The wire says "exactly one locator or none" and the result record carries a
// LIST, so SaveDialogRef.Show narrows it once for every app: cancel is nil, a
// destination is the first locator.
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

	app.Build(func(tx *Tx) { deliver(tx, nil) })
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

// The core answers both dialog kinds on file_dialog_result, so a save request
// drawing from its own counter would steer one dialog's answer to the other.
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

package kaya

// The process-level notification handler (docs/tasks-s9-plan.md R1). A tap
// on a reminder after the app has exited relaunches the process, and THAT
// process never called Show, so the one-shot table is empty for the id
// that started it. Serve's switch has no seam a test can reach — the ring
// is C memory — so these drive App.notificationResult, which the switch
// arm calls and tools/check-sugar-surface.py holds it to calling.

import (
	"io"
	"os"
	"strings"
	"testing"
)

// saidOnStderr runs body with os.Stderr replaced by a pipe and returns what
// was written to it.
func saidOnStderr(t *testing.T, body func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	real := os.Stderr
	os.Stderr = w
	done := make(chan string, 1)
	go func() {
		all, _ := io.ReadAll(r)
		done <- string(all)
	}()
	func() {
		defer func() {
			os.Stderr = real
			w.Close()
		}()
		body()
	}()
	said := <-done
	r.Close()
	return said
}

func TestTheOneShotNotificationHandlerWinsOverTheProcessLevelOne(t *testing.T) {
	app := NewApp()
	var oneShot []uint32
	var process [][2]uint64
	app.OnNotificationActivation(func(tx *Tx, id uint64, outcome uint32) {
		process = append(process, [2]uint64{id, uint64(outcome)})
	})
	app.Build(func(tx *Tx) {
		tx.ShowNotification(12).Title("bound at the show").
			OnResult(func(tx *Tx, outcome uint32) {
				oneShot = append(oneShot, outcome)
			}).Show()
	})

	app.notificationResult(12, NotificationOutcomeActivated)
	if len(oneShot) != 1 || oneShot[0] != NotificationOutcomeActivated {
		t.Fatalf("the one-shot handler did not answer: %v", oneShot)
	}
	if len(process) != 0 {
		t.Fatalf("the process-level handler answered an id that HAD a one-shot handler: %v", process)
	}
}

func TestAnUnknownNotificationIdReachesTheProcessLevelHandler(t *testing.T) {
	app := NewApp()
	var process [][2]uint64
	app.OnNotificationActivation(func(tx *Tx, id uint64, outcome uint32) {
		process = append(process, [2]uint64{id, uint64(outcome)})
	})

	// 77 was never shown by this process — the relaunch case exactly.
	app.notificationResult(77, NotificationOutcomeActivated)
	if len(process) != 1 || process[0] != [2]uint64{77, uint64(NotificationOutcomeActivated)} {
		t.Fatalf("a result with no one-shot handler did not reach the process-level one: %v", process)
	}
}

func TestTheProcessLevelNotificationHandlerDoesNotRetire(t *testing.T) {
	app := NewApp()
	var process [][2]uint64
	app.OnNotificationActivation(func(tx *Tx, id uint64, outcome uint32) {
		process = append(process, [2]uint64{id, uint64(outcome)})
	})

	app.notificationResult(77, NotificationOutcomeActivated)
	app.notificationResult(78, NotificationOutcomeRefused)
	if len(process) != 2 {
		t.Fatalf("the process-level handler retired after its first result: %v", process)
	}
	if process[1] != [2]uint64{78, uint64(NotificationOutcomeRefused)} {
		t.Fatalf("the second tap arrived wrong: %v", process[1])
	}
	if app.notificationActivation == nil {
		t.Fatal("the registration was cleared — the process-level handler is not one-shot")
	}
}

// The third position: a drop nobody announced is the defect class R5
// names, and this sentence is the only signal a relaunched process's
// author gets that nothing was listening.
func TestAnUnclaimedNotificationResultAnnouncesTheDrop(t *testing.T) {
	app := NewApp()
	said := saidOnStderr(t, func() {
		app.notificationResult(41, NotificationOutcomeRefused)
	})
	want := "kaya: notification 41 outcome refused reached no handler — " +
		"none was bound at the show and no process-level handler is " +
		"registered (App.OnNotificationActivation)"
	if strings.TrimSpace(said) != want {
		t.Fatalf("the drop was announced as %q, wanted %q", strings.TrimSpace(said), want)
	}
}

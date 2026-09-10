package kaya

// The process-level notification handler (docs/tasks-s9-plan.md R1). A tap
// on a reminder after the app has exited relaunches the process, and THAT
// process never called Show, so the one-shot table is empty for the id
// that started it. Serve's switch has no seam a test can reach — the ring
// is C memory — so these drive App.notificationResult, which the switch
// arm calls and tools/check-sugar-surface.py holds it to calling.

import (
	"bytes"
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

// THE APP-LINK ROUTES (docs/app-links-plan.md §4). Four cases no lane can
// see: the declaration's BYTES, the ids the counter mints, the dispatch
// by route id, and the two drops — a route that matched and reached no
// handler says so, route 0 says nothing because the CORE already
// announced that miss naming every declared pattern.
func TestALinkRouteParksTheGeneratedRecordAndMintsFromOne(t *testing.T) {
	app := NewApp()
	app.Link("task/{key}", func(tx *Tx, params map[string]string) {})
	app.Link("{section}", func(tx *Tx, params map[string]string) {})
	if len(app.pendingRecords) != 2 {
		t.Fatalf("two declarations parked %d records", len(app.pendingRecords))
	}
	want := [][]byte{
		TxDeclareLinkRoute(1, "task/{key}"),
		TxDeclareLinkRoute(2, "{section}"),
	}
	for i, rec := range want {
		if !bytes.Equal(app.pendingRecords[i], rec) {
			t.Fatalf("parked record %d is not the generated one: %x, wanted %x",
				i, app.pendingRecords[i], rec)
		}
	}
}

// AND THE PARKED DECLARATIONS LEAD THE NEXT TRANSACTION. A route declared
// after the app's first transaction misses the COLD door — the core
// matches the link that started the process the moment that batch lands —
// so the order is the semantics and no scene can read it back.
func TestParkedLinkRoutesLeadTheNextTransaction(t *testing.T) {
	app := NewApp()
	app.Link("task/{key}", func(tx *Tx, params map[string]string) {})
	app.Build(func(tx *Tx) { tx.CreateWindow(1) })
	if len(app.pendingRecords) != 0 {
		t.Fatalf("the transaction left %d declarations parked", len(app.pendingRecords))
	}
	// A second one declared with no transaction open parks again.
	app.Link("{section}", func(tx *Tx, params map[string]string) {})
	if len(app.pendingRecords) != 1 {
		t.Fatalf("a later declaration parked %d records", len(app.pendingRecords))
	}
}

func TestALinkOpenedReachesItsRouteHandlerWithTheParams(t *testing.T) {
	app := NewApp()
	var seen []map[string]string
	app.Link("task/{key}", func(tx *Tx, params map[string]string) {
		seen = append(seen, params)
	})
	app.linkOpened(1, "dev.kaya.aurora.notes://task/t2",
		map[string]string{"key": "t2"})
	if len(seen) != 1 || seen[0]["key"] != "t2" {
		t.Fatalf("the route handler did not answer with its captures: %v", seen)
	}
	// NOT one-shot: a second link on the same route answers again.
	app.linkOpened(1, "dev.kaya.aurora.notes://task/t3",
		map[string]string{"key": "t3"})
	if len(seen) != 2 || seen[1]["key"] != "t3" {
		t.Fatalf("the route registration retired: %v", seen)
	}
}

func TestAnUnknownRouteReachesNoHandlerAndSaysSo(t *testing.T) {
	app := NewApp()
	var seen int
	app.Link("task/{key}", func(tx *Tx, params map[string]string) { seen++ })
	said := saidOnStderr(t, func() {
		app.linkOpened(9, "dev.kaya.aurora.notes://task/t2", nil)
	})
	if seen != 0 {
		t.Fatalf("a route this process never declared reached a handler")
	}
	want := "kaya: link dev.kaya.aurora.notes://task/t2 matched route 9 and " +
		"reached no handler — none is registered for it (App.Link)"
	if strings.TrimSpace(said) != want {
		t.Fatalf("the drop was announced as %q, wanted %q", strings.TrimSpace(said), want)
	}
}

// ROUTE 0 IS THE OTHER DROP, and it is SILENT: a URL no route took is the
// CORE's to announce, naming every declared pattern, and two lines for
// one event teaches a reader to distrust both.
func TestRouteZeroIsDeliveredAndSilent(t *testing.T) {
	app := NewApp()
	app.Link("task/{key}", func(tx *Tx, params map[string]string) {})
	said := saidOnStderr(t, func() {
		app.linkOpened(0, "dev.kaya.aurora.notes://nope", nil)
	})
	if strings.TrimSpace(said) != "" {
		t.Fatalf("route 0 was announced by the binding as well: %q", said)
	}
}

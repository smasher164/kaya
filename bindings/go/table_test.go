package kaya

// The NESTED table's Go spelling, read off the records it queues: a bar
// declared on the template node for every copy, a sort request that
// carries the clicking copy's keys, and those same keys handed back to
// move that one copy's indicator (docs/tables-plan.md, dynamic tables).
// Headless, like the rest of this package's tests.

import (
	"bytes"
	"encoding/binary"
	"testing"
)

type columnHeaders struct {
	widget            uint64
	sorted, direction uint32
	count, pathLen    uint32
	values            []any
}

// decodeColumnHeaders reads the record rather than re-calling the helper
// that wrote it: the defect it catches is a wrong ARGUMENT — titles
// where keys belong, or a path length counting the wrong slice.
func decodeColumnHeaders(t *testing.T, rec []byte) columnHeaders {
	t.Helper()
	if kind := binary.LittleEndian.Uint16(rec[4:]); kind != txSetColumnHeaders {
		t.Fatalf("record kind %d, want set_column_headers (%d)", kind, txSetColumnHeaders)
	}
	h := columnHeaders{
		widget:    binary.LittleEndian.Uint64(rec[8:]),
		sorted:    binary.LittleEndian.Uint32(rec[16:]),
		direction: binary.LittleEndian.Uint32(rec[20:]),
		count:     binary.LittleEndian.Uint32(rec[24:]),
		pathLen:   binary.LittleEndian.Uint32(rec[28:]),
	}
	n := binary.LittleEndian.Uint32(rec[32:])
	at := 40
	for i := uint32(0); i < n; i++ {
		tag := binary.LittleEndian.Uint32(rec[at:])
		size := int(binary.LittleEndian.Uint32(rec[at+4:]))
		body := rec[at+8 : at+8+size]
		switch tag {
		case ValueStr:
			h.values = append(h.values, string(body))
		case ValueI64:
			h.values = append(h.values, int64(binary.LittleEndian.Uint64(body)))
		default:
			t.Fatalf("value %d rode as tag %d — a key lost its type on the way out", i, tag)
		}
		// Values self-pad to 8 because they concatenate (encodeValue).
		at += (8 + size + 7) &^ 7
	}
	return h
}

// abandonProbe is the panic queued() rides back out on.
type abandonProbe struct{}

// queued runs fn as a transaction and hands back the records it wrote,
// keeping them OFF the wire: kaya_submit decodes eagerly and ABORTS the
// process on a malformed record (crates/kaya/src/wire.rs — measured:
// "kaya: a column title is I64(7), wanted a string" when the keys and
// titles are swapped). That is the right wall in a guest, and the wrong
// one here — it takes a perturbation's red away from the assertion that
// names the defect and hands it to a crash, so these assertions could
// never be watched failing. Build abandons on a panic and ships nothing,
// which is the documented exit. The shipped-bytes half is covered by the
// handler test below, which submits for real.
// The return is NAMED: the records are assigned before the panic, and a
// bare `return out` after a recovered panic would hand back the zero
// value instead.
func queued(t *testing.T, app *App, fn func(*Tx)) (out [][]byte) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			if _, ours := r.(abandonProbe); !ours {
				panic(r)
			}
		}
	}()
	app.Build(func(tx *Tx) {
		fn(tx)
		out = append(out, tx.records...)
		panic(abandonProbe{})
	})
	return out
}

func recordsOfKind(recs [][]byte, kind uint16) []int {
	var at []int
	for i, rec := range recs {
		if binary.LittleEndian.Uint16(rec[4:]) == kind {
			at = append(at, i)
		}
	}
	return at
}

// A nested For's bar is declared against the TEMPLATE NODE with no key
// path — one declaration, stamped onto every copy — and the record lands
// in the OPEN PARENT scope, after the nested template closed and before
// the enclosing one does (docs/tables-plan.md, MEASURED IN SLICE 1).
func TestNestedColumnsDeclareTheTemplateNodesBarForEveryCopy(t *testing.T) {
	app := NewApp()
	var positions Node
	recs := queued(t, app, func(tx *Tx) {
		accounts := tx.Collection()
		for account := range tx.Rows(accounts).All() {
			account.Column(func() {
				holdings := account.Collection()
				nested := account.Rows(holdings).
					Columns([]string{"Name", "Size"}, SortNone())
				positions = nested.Node()
				for row := range nested.All() {
					row.Row(func() {
						row.LabelText("name")
						row.LabelText("size")
					})
				}
			})
		}
	})

	bars := recordsOfKind(recs, txSetColumnHeaders)
	if len(bars) != 1 {
		t.Fatalf("the nested table queued %d set_column_headers records, want 1", len(bars))
	}
	h := decodeColumnHeaders(t, recs[bars[0]])
	if h.widget != positions.id {
		t.Fatalf("the bar addresses %d, want the nested For's template node %d — "+
			"a bar on any other id is a different table", h.widget, positions.id)
	}
	if h.pathLen != 0 {
		t.Fatalf("path_len %d, want 0: the template-scoped declaration names no "+
			"copy, so it reaches every one of them", h.pathLen)
	}
	if h.count != 2 || len(h.values) != 2 ||
		h.values[0] != "Name" || h.values[1] != "Size" {
		t.Fatalf("count %d values %v, want 2 and [Name Size]", h.count, h.values)
	}
	if h.sorted != SortNone().sorted {
		t.Fatalf("indicator %d, want the no-indicator sentinel %d",
			h.sorted, SortNone().sorted)
	}

	ends := recordsOfKind(recs, txTemplateEnd)
	if len(ends) != 2 {
		t.Fatalf("found %d template_end records, want 2 (the nested For's and the "+
			"enclosing one's) — the probe is no longer building a nested table",
			len(ends))
	}
	if bars[0] < ends[0] || bars[0] > ends[1] {
		t.Fatalf("the bar is record %d, outside the parent scope (%d..%d). The "+
			"header op finds its For in the OPEN PARENT scope: the nested For "+
			"folds into that scope at its template_end, and a bar emitted before "+
			"that names a For nothing has closed yet",
			bars[0], ends[0], ends[1])
	}
}

// One copy's re-declaration: the template node, then that copy's keys
// OUTERMOST FIRST ahead of the titles, with path_len counting the keys.
func TestColumnsAtEmitsTheCopyKeysBeforeTheTitles(t *testing.T) {
	app := NewApp()
	table := Node{41}
	// TWO keys and THREE titles, deliberately: with the two counts equal,
	// a path_len that counted the titles would be indistinguishable from
	// one that counted the keys and the clause below would pass
	// vacuously (measured — it did).
	keys := []any{"brokerage", int64(7)}
	titles := []string{"Name", "Done", "Size"}
	recs := queued(t, app, func(tx *Tx) {
		tx.ColumnsAt(table, keys, titles, SortDesc(1))
	})

	if len(recs) != 1 {
		t.Fatalf("ColumnsAt queued %d records, want exactly 1", len(recs))
	}
	h := decodeColumnHeaders(t, recs[0])
	if h.widget != table.id {
		t.Fatalf("the bar addresses %d, want the template node %d", h.widget, table.id)
	}
	if h.sorted != 1 || h.direction != 1 {
		t.Fatalf("indicator (%d, %d), want column 1 descending", h.sorted, h.direction)
	}
	if h.count != 3 || h.pathLen != 2 {
		t.Fatalf("count %d path_len %d, want 3 and 2 — path_len counts the KEYS "+
			"and count the TITLES; swapping them makes the root read titles as "+
			"keys", h.count, h.pathLen)
	}
	want := []any{"brokerage", int64(7), "Name", "Done", "Size"}
	if len(h.values) != len(want) {
		t.Fatalf("values %v, want %v", h.values, want)
	}
	for i := range want {
		if h.values[i] != want[i] {
			t.Fatalf("value %d is %#v, want %#v — the Values carry path_len KEYS "+
				"first, then the titles", i, h.values[i], want[i])
		}
	}
	// And the generator's own encoder agrees, byte for byte: what this
	// binding owns is the ARGUMENTS, never the layout.
	frame := TxSetColumnHeaders(table.id, 1, 1, 3, 2, want)
	if !bytes.Equal(recs[0], frame) {
		t.Fatalf("ColumnsAt queued %x, the wire encoder writes %x", recs[0], frame)
	}
}

// The handler scopes to its creator — the nested For — and the copy's
// key path IS the message: what arrives is what goes back out, which is
// how one copy's arrows move while its siblings' stay put.
func TestACopysSortHandlerIsRegisteredAtItsForAndKeepsTheKeyPath(t *testing.T) {
	app := NewApp()
	var positions Node
	app.Build(func(tx *Tx) {
		accounts := tx.Collection()
		for account := range tx.Rows(accounts).All() {
			holdings := account.Collection()
			nested := account.Rows(holdings).
				Columns([]string{"Name"}, SortNone()).
				OnSort(func(tx *Tx, keys []any, column uint32) {
					tx.ColumnsAt(positions, keys, []string{"Name"}, SortAsc(column))
				})
			positions = nested.Node()
			for row := range nested.All() {
				row.Row(func() { row.LabelText("name") })
			}
		}
	})

	if len(app.sortHandlers) != 0 {
		t.Fatalf("OnSortNode also filled the LIVE sort map (%d entries): a nested "+
			"table's clicks arrive with a key path and route by node id",
			len(app.sortHandlers))
	}
	fn := app.nodeSorts[positions.id]
	if fn == nil {
		t.Fatalf("no handler at the nested For's node %d — OnSortNode did not "+
			"register where the sort request will be routed", positions.id)
	}

	var recs [][]byte
	app.Build(func(tx *Tx) {
		fn(tx, []any{"brokerage"}, 0)
		recs = append(recs, tx.records...)
	})
	if len(recs) != 1 {
		t.Fatalf("answering the sort request queued %d records, want 1", len(recs))
	}
	h := decodeColumnHeaders(t, recs[0])
	if h.widget != positions.id || h.pathLen != 1 || len(h.values) != 2 ||
		h.values[0] != "brokerage" {
		t.Fatalf("the answer was node %d path_len %d values %v, want node %d, "+
			"path_len 1 and the clicking copy's key first — a handler that drops "+
			"the path re-declares the bar for every sibling",
			h.widget, h.pathLen, h.values, positions.id)
	}
	if h.sorted != 0 || h.direction != 0 {
		t.Fatalf("indicator (%d, %d), want column 0 ascending", h.sorted, h.direction)
	}
}

// A NESTED table's rows carrying NAMED FIELDS: the record-schema
// constructor stands in the template zone, and narrowing the handle to
// one stamped copy keeps the element type (docs/deferred.md, the
// nested-record-collection gap). Both halves are read off the wire and
// the model, because both lie in ways that COMPILE: a constructor that
// opened its own transaction would emit the create_collection outside
// the parent's scope, and a narrowing that dropped the key would write
// the PARENT's table with no error anywhere.
type nestedPosition struct {
	Symbol string
	Shares string
}

func nestedSymbol(p *nestedPosition) *string { return &p.Symbol }
func nestedShares(p *nestedPosition) *string { return &p.Shares }

func TestANestedRecordCollectionIsDeclaredInTheTemplateAndAddressedTyped(t *testing.T) {
	app := NewApp()
	var positions RecordCollection[string, nestedPosition]
	recs := queued(t, app, func(tx *Tx) {
		accounts := tx.Collection()
		for account := range tx.Rows(accounts).All() {
			// THE TEMPLATE ZONE'S OWN CONSTRUCTOR: the row surface embeds
			// *Tpl and Tpl.tx is unexported, so this free function is the
			// only way into the scope from here.
			positions = TplCollectionOf[string, nestedPosition](account.Tpl)
			nested := account.Rows(positions.Collection)
			for row := range nested.All() {
				row.Row(func() {
					positions.Label(row.Tpl, nestedSymbol)
					positions.Label(row.Tpl, nestedShares)
				})
			}
		}
		tx.Insert(accounts, "brokerage", "Brokerage")
		// `At` KEEPS THE RECORD TYPE, so this is the record insert. An
		// untyped handle here would take a bare value and the row's two
		// fields would be unreachable.
		positions.At("brokerage").Insert(tx, "aapl", nestedPosition{"AAPL", "10"})
	})

	// The collection was born with the RECORD schema: two fields, not the
	// one string a scalar collection carries.
	births := recordsOfKind(recs, txCreateCollection)
	if len(births) != 2 {
		t.Fatalf("the probe queued %d create_collection records, want 2 (the "+
			"accounts table and the nested positions one)", len(births))
	}
	birth := recs[births[1]]
	variants := binary.LittleEndian.Uint32(birth[16:])
	fields := binary.LittleEndian.Uint32(birth[24:])
	if variants != 1 || fields != 2 {
		t.Fatalf("the nested collection's schema is %d variant(s) of %d field(s), "+
			"want 1 of 2 — a record collection born with the scalar schema "+
			"typechecks and leaves every row one string wide", variants, fields)
	}

	// And it was born INSIDE the parent's template scope: after the
	// create_for that opened it, before the template_end that closed it.
	fors := recordsOfKind(recs, txCreateFor)
	ends := recordsOfKind(recs, txTemplateEnd)
	if len(fors) != 2 || len(ends) != 2 {
		t.Fatalf("found %d create_for and %d template_end records, want 2 each — "+
			"the probe is no longer building a nested table", len(fors), len(ends))
	}
	if births[1] < fors[0] || births[1] > ends[1] {
		t.Fatalf("the nested collection is record %d, outside the parent's "+
			"template scope (%d..%d). A collection declared in the LIVE zone is "+
			"one table for every copy, not one per copy",
			births[1], fors[0], ends[1])
	}

	// The typed narrowing addresses the COPY, on the wire.
	inserts := recordsOfKind(recs, txCollectionInsert)
	if len(inserts) != 2 {
		t.Fatalf("the probe queued %d collection_insert records, want 2", len(inserts))
	}
	if pathLen := binary.LittleEndian.Uint32(recs[inserts[1]][16:]); pathLen != 1 {
		t.Fatalf("the record insert carries path_len %d, want 1 — a narrowing "+
			"that drops the key writes the parent's table in silence", pathLen)
	}

	// And in the model, which is the half the wire cannot show: the copy's
	// entry is a nestedPosition, and the collection's own table is empty.
	app2 := NewApp()
	var copyEntries, ownEntries []RecordEntry[string, nestedPosition]
	app2.Build(func(tx *Tx) {
		var inner RecordCollection[string, nestedPosition]
		accounts := tx.Collection()
		for account := range tx.Rows(accounts).All() {
			inner = TplCollectionOf[string, nestedPosition](account.Tpl)
			for row := range account.Rows(inner.Collection).All() {
				row.Row(func() { inner.Label(row.Tpl, nestedSymbol) })
			}
		}
		tx.Insert(accounts, "brokerage", "Brokerage")
		inner.At("brokerage").Insert(tx, "aapl", nestedPosition{"AAPL", "10"})
		copyEntries = inner.At("brokerage").Items(tx)
		ownEntries = inner.Items(tx)
	})
	if len(copyEntries) != 1 || copyEntries[0].Key != "aapl" ||
		copyEntries[0].Value != (nestedPosition{"AAPL", "10"}) {
		t.Fatalf("the copy's model holds %v, want one aapl/AAPL/10 record — the "+
			"typed At is what keeps the mirror's entries records rather than "+
			"bare values", copyEntries)
	}
	if len(ownEntries) != 0 {
		t.Fatalf("the collection's OWN table holds %d entries; the write was "+
			"addressed to a copy and must not reach it", len(ownEntries))
	}
}

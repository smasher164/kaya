package kaya

// The generated shortcut canonicalizer's negative table (the one
// binding-tier parser; DESIGN.md, Menus): spelling is canonicalized
// here, POLICY (escape, shift-only/bare alphanumerics, the reserved
// floor) dies at the core on the canonical form. The vectors mirror
// kaya-bindgen's reference table (tools/kaya-bindgen/src/main.rs) —
// the shared statement of the algorithm every emitter transcribes.

import (
	"bytes"
	"testing"
)

func TestCanonicalizeShortcutAccepts(t *testing.T) {
	cases := []struct{ in, want string }{
		{"primary+s", "primary+s"},
		{"PRIMARY+S", "primary+s"},
		{"Shift+Primary+S", "primary+shift+s"},
		{"alt+shift+f5", "shift+alt+f5"},
		{"ALT+ENTER", "alt+enter"},
		{"primary+alt+0", "primary+alt+0"},
		{"enter", "enter"},
		{"f12", "f12"},
		// Recognized at the binding tier, rejected by the core (policy):
		{"Escape", "escape"},
		{"shift+s", "shift+s"},
		{"q", "q"},
		{"primary+q", "primary+q"},
		{"alt+f4", "alt+f4"},
	}
	for _, c := range cases {
		if got := CanonicalizeShortcut(c.in); got != c.want {
			t.Errorf("CanonicalizeShortcut(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestCanonicalizeShortcutRejects(t *testing.T) {
	cases := []string{
		"",
		"primary + s",
		" primary+s",
		"primary+s ",
		"ctrl+s",
		"cmd+s",
		"option+p",
		"control+s",
		"command+s",
		"primary+primary+s",
		"primary+shift+shift+s",
		"primary+",
		"+s",
		"primary++s",
		"primary+s+k",
		"s+primary",
		"primary",
		"shift+alt",
		"primary+esc",
		"primary+f13",
		"primary+f0",
		"primary+f01",
		"primary+ss",
	}
	for _, c := range cases {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("CanonicalizeShortcut(%q) should panic", c)
				}
			}()
			CanonicalizeShortcut(c)
		}()
	}
}

// TxSetMenuShortcut routes through the canonicalizer — no call site
// can bypass it: a case-variant spelling packs the canonical bytes,
// and a bad one panics before any record is framed.
func TestTxSetMenuShortcutCanonicalizes(t *testing.T) {
	if !bytes.Equal(TxSetMenuShortcut(7, "SHIFT+PRIMARY+S"), TxSetMenuShortcut(7, "primary+shift+s")) {
		t.Error("TxSetMenuShortcut did not canonicalize the spelling")
	}
	defer func() {
		if recover() == nil {
			t.Error("TxSetMenuShortcut(\"ctrl+s\") should panic")
		}
	}()
	TxSetMenuShortcut(7, "ctrl+s")
}

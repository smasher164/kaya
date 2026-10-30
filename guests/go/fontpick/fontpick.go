// The font picker scene, Go port: guests/rust/fontpick.rs,
// tools/scenes/fontpick.steps (docs/font-picker-plan.md §7).
package fontpick

import (
	"fmt"
	"slices"

	kaya "dev.kaya/bindings/go"
)

var mono = []string{"Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas", "Courier New",
	"Droid Sans Mono", "monospace"}

const doc = "bold run, italic run, plain run"

func words(weight int, italic bool, width int) string {
	slope := "upright"
	if italic {
		slope = "italic"
	}
	return fmt.Sprintf("%d %s %d", weight, slope, width)
}

func lightFamily(faces []kaya.FontFace) (light, a, b int, ok bool) {
	var upright, italic []int
	for _, f := range faces {
		if f.Width != 5 {
			continue
		}
		if f.Italic {
			italic = append(italic, f.Weight)
		} else {
			upright = append(upright, f.Weight)
		}
	}
	if len(upright) < 3 || !slices.Contains(upright, 700) {
		return 0, 0, 0, false
	}
	found := false
	for _, w := range upright {
		if w < 400 && slices.Contains(italic, w) {
			light, found = w, true
			break
		}
	}
	if !found {
		return 0, 0, 0, false
	}
	for i := 1; i < len(upright); i++ {
		if upright[i-1] >= 500 && upright[i] > upright[i-1]+1 {
			return light, upright[i-1], upright[i], true
		}
	}
	return 0, 0, 0, false
}

func uprightOnly(faces []kaya.FontFace) (int, bool) {
	if len(faces) == 0 {
		return 0, false
	}
	for _, f := range faces {
		if f.Italic {
			return 0, false
		}
	}
	for _, f := range faces {
		if f.Width == 5 {
			return f.Weight, true
		}
	}
	return 0, false
}

func noBold(faces []kaya.FontFace) bool {
	if len(faces) == 0 {
		return false
	}
	for _, f := range faces {
		if f.Weight >= 600 {
			return false
		}
	}
	return true
}

func App() *kaya.App {
	app := kaya.NewApp()

	var ready, pick, picked kaya.Signal[string]
	var want [7]kaya.Signal[string]
	var exact, between, synth, heavy, text, chosen kaya.Widget

	var queue []string
	var lightName, plainName, monoName, heavyName string
	var lw, la, lb, pw int
	var asked *kaya.FontChoice

	app.OnFontFamilies(func(tx *kaya.Tx, families []string) {
		for _, m := range mono {
			if slices.Contains(families, m) {
				monoName = m
				break
			}
		}
		queue = slices.Clone(families)
		slices.Reverse(queue)
		if monoName != "" {
			queue = append(queue, monoName)
		}
		if len(queue) > 0 {
			next := queue[len(queue)-1]
			queue = queue[:len(queue)-1]
			tx.ListFontFaces(next)
		}
	})

	app.OnFontFaces(func(tx *kaya.Tx, family string, faces []kaya.FontFace) {
		if family == monoName && asked == nil {
			var face *kaya.FontFace
			for i := range faces {
				if faces[i].Weight == 700 && !faces[i].Italic && faces[i].Width == 5 {
					face = &faces[i]
					break
				}
			}
			if face == nil && len(faces) > 0 {
				face = &faces[0]
			}
			if face != nil {
				asked = &kaya.FontChoice{Family: family, Weight: face.Weight, Italic: face.Italic, Width: face.Width}
			}
		}
		if lightName == "" {
			if l, a, b, ok := lightFamily(faces); ok {
				lightName, lw, la, lb = family, l, a, b
			}
		}
		if plainName == "" {
			if w, ok := uprightOnly(faces); ok {
				plainName, pw = family, w
			}
		}
		if heavyName == "" && noBold(faces) {
			heavyName = family
		}
		if lightName == "" || plainName == "" || heavyName == "" {
			if len(queue) > 0 {
				next := queue[len(queue)-1]
				queue = queue[:len(queue)-1]
				tx.ListFontFaces(next)
			} else {
				tx.Write(ready, "faces: none suit")
			}
			return
		}
		tx.SetFamily(exact, lightName)
		tx.SetFontWeight(exact, lw)
		tx.SetFamily(between, lightName)
		tx.SetFontWeight(between, la+(lb-la)/2)
		tx.SetFamily(synth, plainName)
		tx.SetFontWeight(synth, pw)
		tx.SetFontItalic(synth, true)
		tx.SetFamily(heavy, heavyName)
		tx.SetFontWeight(heavy, 700)
		tx.SetFamily(text, lightName)
		tx.SetFontWeight(text, lw)
		tx.SetDocument(text, kaya.NewDocument(doc).Bold(0, 4).Italic(10, 16))
		tx.Write(want[0], words(lw, false, 5))
		tx.Write(want[1], words(lb, false, 5))
		tx.Write(want[2], words(pw, true, 5)+" synthesized")
		tx.Write(want[3], words(700, false, 5))
		tx.Write(want[4], words(lw, true, 5))
		tx.Write(want[6], words(700, false, 5)+" synthesized")
		if asked != nil {
			tx.Write(pick, words(asked.Weight, asked.Italic, asked.Width)+" "+asked.Family)
			tx.Write(want[5], words(asked.Weight, asked.Italic, asked.Width))
		}
		tx.Write(ready, "faces: found")
	})

	onChosen := func(tx *kaya.Tx, c *kaya.FontChoice) {
		if c == nil {
			tx.Write(picked, "picked: cancelled")
			return
		}
		tx.SetFamily(chosen, c.Family)
		tx.SetFontWeight(chosen, c.Weight)
		tx.SetFontItalic(chosen, c.Italic)
		tx.SetFontWidth(chosen, c.Width)
		if asked != nil && *c == *asked {
			tx.Write(picked, "picked: as asked")
		} else {
			tx.Write(picked, "picked: "+words(c.Weight, c.Italic, c.Width)+" "+c.Family)
		}
	}

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("fontpick")
		ready = tx.Signal("faces: -")
		for i := range want {
			want[i] = tx.Signal("-")
		}
		pick = tx.Signal("-")
		picked = tx.Signal("picked: -")

		tx.Mount(tx.Column(func() {
			tx.Label(ready).A11yID("ready")
			exact = tx.LabelText("Exact").A11yID("exact")
			between = tx.LabelText("Between").A11yID("between")
			synth = tx.LabelText("Slanted").A11yID("synth")
			heavy = tx.Entry(nil).A11yID("heavy")
			tx.SetText(heavy, "Heavy")
			text = tx.Textarea(nil).Rich().A11yID("doc")
			chosen = tx.LabelText("Chosen").A11yID("chosen")
			for i, id := range []string{"want_exact", "want_between", "want_synth", "want_bold",
				"want_italic", "want_pick", "want_heavy"} {
				tx.Label(want[i]).A11yID(id)
			}
			tx.Label(pick).A11yID("pick")
			tx.Label(picked).A11yID("picked")
			tx.Row(func() {
				tx.Button("faces", func(tx *kaya.Tx) { tx.ListFontFamilies() }).A11yID("faces")
				tx.Button("pick", func(tx *kaya.Tx) {
					r := tx.ChooseFont().CodeOnly(true).Faces(true).OnResult(onChosen)
					if asked != nil {
						r = r.Initial(*asked)
					}
					r.Show()
				}).A11yID("pick_button")
			})
		}))
	})

	return app
}

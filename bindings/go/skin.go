// The skin (docs/styling-pass-plan.md Y2-Y8): grounds, an image's shape, a
// label's tint, the activatable container with its selected surface, the
// dock and the core's dominant colour, in both zones where the prop lives.
package kaya

/*
#include <kaya.h>
#include <stdint.h>
*/
import "C"

import "unsafe"

// Shape is an image's clip: ShapeRect, ShapeRounded (the platform's medium
// corner) or ShapeCircle (the inscribed circle, covering).
type Shape int64

// ImageDominant is the dominant colour of a PNG or JPEG, the core's one
// quantizer; false for bytes that do not decode.
func ImageDominant(bytes []byte) (Color, bool) {
	if len(bytes) == 0 {
		return Color{}, false
	}
	var rgb C.uint32_t
	if C.kaya_image_dominant((*C.uint8_t)(unsafe.Pointer(&bytes[0])), C.uintptr_t(len(bytes)), &rgb) == 0 {
		return Color{}, false
	}
	return ColorRGB(uint8(rgb>>16), uint8(rgb>>8), uint8(rgb)), true
}

// SetGroundGradient gives a row or column a ground fading from color,
// clamped by the core for the appearance's text, into the window's ground.
func (tx *Tx) SetGroundGradient(w Widget, color Color) {
	tx.emit(TxSetGround(w.id, GroundGradient))
	tx.emit(TxSetColor(w.id, color.R, color.G, color.B, color.A))
}

// GroundGradient is SetGroundGradient's chain.
func (w Widget) GroundGradient(color Color) Widget {
	w.tx.SetGroundGradient(w, color)
	return w
}

// BindGroundGradient takes the gradient's colour from a signal.
func (w Widget) BindGroundGradient(s Signal[Color]) Widget {
	w.tx.emit(TxSetGround(w.id, GroundGradient))
	w.tx.emit(TxBindColor(w.id, s.id))
	return w
}

// SetGroundImage covers a row or column with a picture; text over it sits
// inside a container filled with TintOverlay.
func (tx *Tx) SetGroundImage(w Widget, source []byte) {
	tx.emit(TxSetGround(w.id, GroundImage))
	tx.SetSource(w, source)
}

// GroundImage is SetGroundImage's chain.
func (w Widget) GroundImage(source []byte) Widget {
	w.tx.SetGroundImage(w, source)
	return w
}

// BindGroundImage takes the ground's picture from a blob signal.
func (w Widget) BindGroundImage(s Signal[[]byte]) Widget {
	w.tx.emit(TxSetGround(w.id, GroundImage))
	w.tx.BindSource(w, s)
	return w
}

// SetShape clips an image.
func (tx *Tx) SetShape(w Widget, shape Shape) { tx.emit(TxSetShape(w.id, int64(shape))) }

// Shape is SetShape's chain.
func (w Widget) Shape(shape Shape) Widget {
	w.tx.SetShape(w, shape)
	return w
}

// SetTint draws a label in the tint's standalone colour; TintNone is the
// untinted text.
func (tx *Tx) SetTint(w Widget, tint Tint) { tx.emit(TxSetTint(w.id, int64(tint))) }

// Tint is SetTint's chain.
func (w Widget) Tint(tint Tint) Widget {
	w.tx.SetTint(w, tint)
	return w
}

// BindTint reads a label's tint from a signal.
func (w Widget) BindTint(s Signal[Tint]) Widget {
	w.tx.emit(TxBindTint(w.id, s.id))
	return w
}

// SetSelected puts an activatable container on the platform's selected
// surface: the app's state, written where it wants it.
func (tx *Tx) SetSelected(w Widget, on bool) { tx.emit(TxSetSelected(w.id, on)) }

// Selected is SetSelected's chain.
func (w Widget) Selected(on bool) Widget {
	w.tx.SetSelected(w, on)
	return w
}

// BindSelected reads the selected state from a signal.
func (w Widget) BindSelected(s Signal[bool]) Widget {
	w.tx.emit(TxBindSelected(w.id, s.id))
	return w
}

// OnActivate makes a row or column take a click as a whole: a button to
// assistive technology, the platform's press, hover and selected surface.
// Registering the handler and declaring the container activatable are one
// act.
func (w Widget) OnActivate(fn func(*Tx)) Widget {
	w.tx.app.widgetActivates[w.id] = fn
	w.tx.emit(TxSetActivatable(w.id, true))
	return w
}

// OnActivate makes every stamped copy of a container take a click as a
// whole; the handler also receives the copy's keys, outermost first.
func (n Node) OnActivate(fn func(*Tx, []any)) Node {
	n.tx.app.nodeActivates[n.id] = fn
	n.tx.emit(TxSetActivatable(n.id, true))
	return n
}

// OnSelect hears the user's pick of a row or column
// (docs/styling-pass-plan.md Y4, AMENDED 2026-10-17); the container is
// activatable in the same act, and the app writes SetSelected itself.
func (w Widget) OnSelect(fn func(*Tx)) Widget {
	w.tx.app.widgetSelects[w.id] = fn
	w.tx.emit(TxSetActivatable(w.id, true))
	return w
}

// OnSelect hears the user's pick of a stamped copy, with the copy's keys,
// outermost first.
func (n Node) OnSelect(fn func(*Tx, []any)) Node {
	n.tx.app.nodeSelects[n.id] = fn
	n.tx.emit(TxSetActivatable(n.id, true))
	return n
}

// SetGroundGradient gives every stamped copy the gradient ground from one
// colour, the blueprint twin of Tx.SetGroundGradient.
func (t *Tpl) SetGroundGradient(n Node, color Color) {
	t.tx.emit(TxSetGround(n.id, GroundGradient))
	t.tx.emit(TxSetColor(n.id, color.R, color.G, color.B, color.A))
}

// BindGroundGradient takes each copy's gradient colour from the row's
// field or a signal: each album its own colour.
func (t *Tpl) BindGroundGradient[S interface {
	Signal[Color] | Field[Color]
}](n Node, src S) {
	t.tx.emit(TxSetGround(n.id, GroundGradient))
	switch v := any(src).(type) {
	case Signal[Color]:
		t.tx.emit(TxBindColor(n.id, v.id))
	case Field[Color]:
		t.tx.emit(TxBindColorElement(n.id, 0, v.index))
	}
}

// SetGroundImage covers every stamped copy with one picture.
func (t *Tpl) SetGroundImage(n Node, source []byte) {
	t.tx.emit(TxSetGround(n.id, GroundImage))
	t.tx.emit(TxSetSource(n.id, uint64(blobWire(source))))
}

// BindGroundImage takes each copy's ground picture from the row's field or
// a blob signal.
func (t *Tpl) BindGroundImage[S interface {
	Signal[[]byte] | Field[[]byte]
}](n Node, src S) {
	t.tx.emit(TxSetGround(n.id, GroundImage))
	t.applyBlob(n, src)
}

// SetShape clips every stamped copy of an image.
func (t *Tpl) SetShape(n Node, shape Shape) { t.tx.emit(TxSetShape(n.id, int64(shape))) }

// SetTint tints every stamped copy of a label.
func (t *Tpl) SetTint(n Node, tint Tint) { t.tx.emit(TxSetTint(n.id, int64(tint))) }

// BindTint reads each copy's tint from the row's field or a signal: the
// playing track's title.
func (t *Tpl) BindTint[S interface {
	Signal[Tint] | Field[Tint]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[Tint]:
		t.tx.emit(TxBindTint(n.id, v.id))
	case Field[Tint]:
		t.tx.emit(TxBindTintElement(n.id, 0, v.index))
	}
}

// SetSelected puts every stamped copy on the selected surface.
func (t *Tpl) SetSelected(n Node, on bool) { t.tx.emit(TxSetSelected(n.id, on)) }

// BindSelected reads each copy's selected state from the row's field or a
// signal.
func (t *Tpl) BindSelected[S interface {
	Signal[bool] | Field[bool]
}](n Node, src S) {
	switch v := any(src).(type) {
	case Signal[bool]:
		t.tx.emit(TxBindSelected(n.id, v.id))
	case Field[bool]:
		t.tx.emit(TxBindSelectedElement(n.id, 0, v.index))
	}
}

// Dock gives this window its DOCK, the surface under every pane and above
// a phone's tab bar: dock is a fresh surface id, and build makes the root
// it shows. One per window.
func (w WindowRef) Dock(dock uint64, build func() Widget) WindowRef {
	w.tx.emit(TxAttachDock(w.id, dock))
	w.tx.MountIn(dock, build())
	return w
}

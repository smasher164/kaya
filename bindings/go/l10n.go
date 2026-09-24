// The formatter door and the catalog (docs/compliance-plan.md §1.4, the Go
// row): pure calls over the core's kaya_fmt_*, kaya_locale, kaya_direction,
// kaya_text_scale, kaya_catalog and kaya_tr. Any goroutine, no transaction.
package kaya

/*
#include <kaya.h>
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"strconv"
	"strings"
	"unsafe"
)

// Length is how much of a date or time to write: Short is the numeric
// form, Medium the abbreviated words, Long the full words.
type Length int

const (
	Short  Length = 0
	Medium Length = 1
	Long   Length = 2
)

// NumberOptions is what a number formatter may be told; a nil
// *NumberOptions is the platform's defaults, and a negative digit count
// leaves that field at the platform's default.
type NumberOptions struct {
	MinFractionDigits int
	MaxFractionDigits int
	Grouping          bool
}

// LayoutDirection is which way the layout runs, decided by the locale's
// script; Direction() answers it.
type LayoutDirection int

const (
	LTR LayoutDirection = 0
	RTL LayoutDirection = 1
)

func (d LayoutDirection) String() string {
	if d == RTL {
		return "rtl"
	}
	return "ltr"
}

// LocaleInfo is who the user is, as the platform reports it.
type LocaleInfo struct {
	// BCP-47, "en-US" never "en_US".
	Tag string
	// 12 or 24.
	HourCycle int
	// 1 is Monday, 7 is Sunday.
	FirstWeekday int
	// CLDR's calendar name: "gregorian", "japanese", …
	Calendar string
	// CLDR's numbering system: "latn", "arab", …
	Numbering string
}

// Args carries a message's arguments: int, int64, float64, string, Date
// or Time under the names the catalog's placeables use.
type Args map[string]any

// filled runs one string-out core call twice, the ask-size-ask shape
// (prefGetString's), and refuses a 0 answer by name: the core reported a
// fault through kaya's own channel and a silent "" would hide it.
func filled(what string, call func(out *C.uint8_t, cap C.size_t) C.size_t) string {
	needed := call(nil, 0)
	if needed == 0 {
		panic("kaya: " + what + " answered nothing — the core reported a fault (see its diagnostics)")
	}
	out := make([]byte, int(needed))
	written := call((*C.uint8_t)(unsafe.Pointer(&out[0])), needed)
	return string(out[:min(int(written), int(needed))])
}

func lengthCode(length Length) C.int64_t {
	if length < Short || length > Long {
		panic(fmt.Sprintf("kaya: %d is not a Length (Short, Medium, Long)", int(length)))
	}
	return C.int64_t(length)
}

// FormatDate writes d at length in the process locale.
func FormatDate(d Date, length Length) string {
	packed, code := C.int64_t(d.packed()), lengthCode(length)
	return filled("FormatDate", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_fmt_date(packed, code, out, cap)
	})
}

// FormatDateWeekday writes d with its weekday and no year ("Mon, Sep 7").
func FormatDateWeekday(d Date) string {
	packed := C.int64_t(d.packed())
	return filled("FormatDateWeekday", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_fmt_date_weekday(packed, out, cap)
	})
}

// FormatTime writes t at length in the process locale and the user's hour cycle.
func FormatTime(t Time, length Length) string {
	packed, code := C.int64_t(t.packed()), lengthCode(length)
	return filled("FormatTime", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_fmt_time(packed, code, out, cap)
	})
}

// FormatDateTime writes both together at one length.
func FormatDateTime(d Date, t Time, length Length) string {
	date, tm, code := C.int64_t(d.packed()), C.int64_t(t.packed()), lengthCode(length)
	return filled("FormatDateTime", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_fmt_date_time(date, tm, code, out, cap)
	})
}

func numberOptions(o *NumberOptions) *C.KayaNumberOptions {
	if o == nil {
		return nil
	}
	return &C.KayaNumberOptions{
		min_fraction_digits: C.int32_t(o.MinFractionDigits),
		max_fraction_digits: C.int32_t(o.MaxFractionDigits),
		grouping:            C.bool(o.Grouping),
	}
}

// FormatNumber writes v with the locale's separators; nil o is the
// platform's defaults.
func FormatNumber(v float64, o *NumberOptions) string {
	opts := numberOptions(o)
	return filled("FormatNumber", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_fmt_number(C.double(v), opts, out, cap)
	})
}

// FormatPercent writes the fraction v as the locale's percentage (0.256 is "26%").
func FormatPercent(v float64, o *NumberOptions) string {
	opts := numberOptions(o)
	return filled("FormatPercent", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_fmt_percent(C.double(v), opts, out, cap)
	})
}

// FormatCurrency writes v in the currency named by its ISO 4217 code.
func FormatCurrency(v float64, code string) string {
	cs := C.CString(code)
	defer C.free(unsafe.Pointer(cs))
	return filled("FormatCurrency", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_fmt_currency(C.double(v), cs, out, cap)
	})
}

// Locale answers the process locale and its settings, asked of the
// platform each time.
func Locale() LocaleInfo {
	line := filled("Locale", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_locale(out, cap)
	})
	parts := strings.Fields(line)
	if len(parts) != 5 {
		panic("kaya: kaya_locale answered " + strconv.Quote(line) + ", not five fields")
	}
	cycle, _ := strconv.Atoi(parts[1])
	first, _ := strconv.Atoi(parts[2])
	return LocaleInfo{Tag: parts[0], HourCycle: cycle, FirstWeekday: first, Calendar: parts[3], Numbering: parts[4]}
}

// Direction answers the layout direction the locale asks for.
func Direction() LayoutDirection {
	if C.kaya_direction() == 1 {
		return RTL
	}
	return LTR
}

// TextScale answers the text scale the platform reported, 1.0 until one does.
func TextScale() float64 { return float64(C.kaya_text_scale()) }

// Catalog loads the app's catalog, l10n/<app>.<locale>.ftl under the asset
// root with the fallback chain. Once, at startup, before any Tr.
func Catalog(app string) {
	cs := C.CString(app)
	defer C.free(unsafe.Pointer(cs))
	C.kaya_catalog(cs)
}

// Tr answers the message key with args filled from the loaded catalog.
// A missing key or argument is the core's own panic naming it.
func Tr(key string, args Args) string {
	ckey := C.CString(key)
	defer C.free(unsafe.Pointer(ckey))
	records := make([]C.KayaTrArg, 0, len(args))
	var owned []unsafe.Pointer
	defer func() {
		for _, p := range owned {
			C.free(p)
		}
	}()
	for name, value := range args {
		cname := C.CString(name)
		owned = append(owned, unsafe.Pointer(cname))
		r := C.KayaTrArg{name: cname}
		switch v := value.(type) {
		case int:
			r.tag, r.i = C.KAYA_TR_INT, C.int64_t(v)
		case int64:
			r.tag, r.i = C.KAYA_TR_INT, C.int64_t(v)
		case float64:
			r.tag, r.f = C.KAYA_TR_FLOAT, C.double(v)
		case string:
			cs := C.CString(v)
			owned = append(owned, unsafe.Pointer(cs))
			r.tag, r.s = C.KAYA_TR_STR, cs
		case Date:
			r.tag, r.i = C.KAYA_TR_DATE, C.int64_t(v.packed())
		case Time:
			r.tag, r.i = C.KAYA_TR_TIME, C.int64_t(v.packed())
		default:
			panic(fmt.Sprintf("kaya: Tr(%q): argument %q is a %T; the arguments are int, int64, float64, string, Date and Time", key, name, value))
		}
		records = append(records, r)
	}
	var first *C.KayaTrArg
	if len(records) > 0 {
		first = &records[0]
	}
	n := C.size_t(len(records))
	return filled("Tr("+strconv.Quote(key)+")", func(out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_tr(ckey, first, n, out, cap)
	})
}

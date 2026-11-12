// The .kdoc file pair (docs/rich-document-plan.md §4, RD13): one codec in
// the core behind kaya_kdoc_read and kaya_kdoc_write, so nine bindings write
// the same bytes.
package kaya

/*
#include <kaya.h>
*/
import "C"

import (
	"encoding/binary"
	"errors"
	"fmt"
	"unsafe"
)

// Kdoc is a .kdoc file read: the document, and ReadOnly naming why it may
// only be read when it carries a name this kaya cannot keep through an edit
// (RD8); "" when it can be edited.
type Kdoc struct {
	Document Document
	ReadOnly string
}

// kdocCall is the two-call door: the size, then the answer's values.
func kdocCall(input []byte, call func(in *C.uint8_t, n C.size_t, out *C.uint8_t, cap C.size_t) C.size_t) []any {
	var in *C.uint8_t
	if len(input) > 0 {
		in = (*C.uint8_t)(unsafe.Pointer(&input[0]))
	}
	needed := call(in, C.size_t(len(input)), nil, 0)
	out := make([]byte, int(needed))
	call(in, C.size_t(len(input)), (*C.uint8_t)(unsafe.Pointer(&out[0])), needed)
	count := int(binary.LittleEndian.Uint32(out))
	vals := make([]any, count)
	at := 8
	for i := range vals {
		vals[i], at = parseValue(out, at)
	}
	return vals
}

// FromKdoc reads a .kdoc file's bytes; refused in one sentence when they are
// not one, or name a newer major version.
func FromKdoc(data []byte) (Kdoc, error) {
	vals := kdocCall(data, func(in *C.uint8_t, n C.size_t, out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_kdoc_read(in, n, out, cap)
	})
	if refusal := vals[0].(string); refusal != "" {
		return Kdoc{}, errors.New(refusal)
	}
	doc := Document{Text: vals[3].(string), Extra: vals[2].(string)}
	for i := 4; i+3 < len(vals); i += 4 {
		doc.Runs = append(doc.Runs, TextRun{
			Range: decodedSpan("kdoc run", int(vals[i].(int64)), int(vals[i+1].(int64))),
			Name:  vals[i+2].(string),
			Value: vals[i+3].(string),
		})
	}
	return Kdoc{Document: doc, ReadOnly: vals[1].(string)}, nil
}

// ToKdoc writes the document as a .kdoc file, the same bytes in nine
// bindings (RD13). It panics naming the run when the document breaks a wall
// Tx.SetDocument holds.
func (d Document) ToKdoc() []byte {
	vals := kdocCall(documentBlob(d), func(in *C.uint8_t, n C.size_t, out *C.uint8_t, cap C.size_t) C.size_t {
		return C.kaya_kdoc_write(in, n, out, cap)
	})
	if refusal := vals[0].(string); refusal != "" {
		panic(fmt.Sprintf("kaya: ToKdoc: %s", refusal))
	}
	return []byte(vals[1].(string))
}

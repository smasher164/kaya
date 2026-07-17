// The encode benchmark: pins "derives target the encoder, not a value
// tree" (DESIGN.md, milestone 3) as a suite leg. Encodes N
// collection_insert records through the generated wire encoder and
// requires a floor rate with ~10x headroom — only a structural
// regression (per-record reflection, tree building) can trip it.
package main

import (
	"fmt"
	"os"
	"time"

	kaya "dev.kaya/bindings/go"
)

func main() {
	const n = 200_000
	const floor = 100_000 // records/second

	start := time.Now()
	var sink int
	for i := 0; i < n; i++ {
		rec := kaya.TxCollectionInsert(1, nil, fmt.Sprintf("k%d", i&1023),
			[]any{"send report", false})
		sink += len(rec)
	}
	elapsed := time.Since(start).Seconds()

	rate := int(float64(n) / elapsed)
	if rate >= floor {
		fmt.Printf("ENCODE_BENCH: OK (go: %d rec/s)\n", rate)
		_ = sink
		return
	}
	fmt.Fprintf(os.Stderr, "ENCODE_BENCH: FAIL (go: %d rec/s, floor %d)\n", rate, floor)
	os.Exit(1)
}

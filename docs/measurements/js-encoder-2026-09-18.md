# JS wire encoder, 2026-09-18

The generated encoder now writes scalars into one reusable growable buffer
and returns an owned slice per record. The transaction still collects those
records and runtime.submit still joins them. This is option A from the
handoff. No protocol, decoder, guest API or transaction semantics changes.

## Actual-module measurement

Node 24.19.0 on the development Mac. The benchmark imports the real
generated module, retaining each record in an array as the binding does.
Each collection insert has an I64 key, an empty path, variant zero, three
strings and two number fields. The large batch has 15,003 records and
2,200,456 bytes; the handler has 20 records and 2,880 bytes.

Run `nix develop -c node docs/probes/js-encoder-bench.mjs`. An optional
absolute module path selects an encoder saved before a change. Warmup is
100 batches of 200 records. Each measurement takes the best of 40 samples;
each handler sample packs 1,000 batches. This measures packing, including
record allocation, but excludes runtime.submit and the core.

| Shape | Original best | Cursor best | Speedup | Original median | Cursor median |
|---|---:|---:|---:|---:|---:|
| 15,003 inserts | 62.9666 ms | 5.7671 ms | 10.92x | 69.7313 ms | 6.4573 ms |
| 20 inserts | 87.7921 µs | 7.5885 µs | 11.57x | 91.6765 µs | 8.0512 µs |

The September 2 probe measured a different, smaller record mix (600,128
bytes). Its 15.6x estimate is historical and is not the result above.
Option A removes the measured scalar-allocation cost while preserving
record ownership and the submit/test interfaces. These results do not
establish a need to change the entire transaction to one buffer (option B).

## Bytes and guards

The original generated module was saved before the edit. A corpus enumerated
all 208 exported tx functions from the module and read their parameter types
from the generated signatures. All 3,744 records were byte-identical after
regeneration. Cases included zero, 2^32+1 and the maximum safe id, both
booleans, F64 zero and -1.5, a negative I64, string lengths zero through nine,
non-ASCII and supplementary characters, lone surrogates, BlobHandle, lists
of zero/one/three values, and empty/empty-variant/multiple-variant schemas.
Date/time components and shortcut spellings used their own valid ranges.

The golden table in bindings/js/kaya_app_checks.ts is derived from the wire
grammar, independently of the encoder: an eight-byte little-endian header
contains size/kind/flags; a value has type/length followed by payload padded
to eight; a list has count/reserved followed by values. Bool, F64, I64,
UTF-8 string, empty record, three-value list, variant schema and blob each
have a fixed hex record. The list is 104 bytes; the two-variant schema is
48 bytes with its trailing four padding bytes. The I64 and blob cases also
exercise both halves of a u64 id or handle.

Eight doctored encoder copies each made the corresponding golden fail:
boolean inversion, F64 endianness, I64 endianness, string length, empty
record kind, value count, variant count and blob handle. Every substitution
count was one. A ninth copy dropped string padding and differed from the
saved corpus in 162 records. A terminal string's padding can be supplied by
record-end padding, so that perturbation is witnessed by strings inside
lists, not by the terminal-string golden alone.

Additional durable checks cover a string beyond the initial 4,096-byte
buffer (including lone-surrogate repair by TextEncoder), zeroing reused
padding, record ownership across growth/reuse, and starting cleanly after
an invalid value partially wrote a record. Strings use TextEncoder.encodeInto;
there is no hand-written UTF-8 writer. Integer refusal sentences are intact.
Four more copies disabled growth, filled padding with nonzero bytes,
returned shared views, or removed the record reset. Each made its corresponding
check fail, with one substitution printed. Thirteen perturbations in total
were applied and observed.

These checks run through the existing js-app-checks gate. The generator's
staleness wall refuses an ordinary core build until regeneration, and every
desktop JS leg exercises the core's wire decoder. Performance is recorded
as a benchmark rather than a load-sensitive gate threshold.

The binding assessment is JS: do, optimize internal encoding. Rust, Python,
Go, C#, Java, Swift, OCaml and Haskell: do, verify their generated output
remains unchanged. None needs a surface change or a semantic carve-out.

## Validation

Regeneration and its check, strict TypeScript over three binding sources
and 51 guests, and all 262 JS checks passed. The Rust harness suite passed
628 tests and 18 doc tests, with one doc test ignored. Four generator tests,
check-steps, ledger and document reference checks passed. The six hand-run
JS legs passed: todos (with a build), richrows, dnd, clipboard, filedialog
and table. The standalone gate sweep passed 61/61. The complete mac lane
passed 477 legs and its own 61/61 gate sweep.

The five-lane matrix passed on 2026-09-18, in 1,497 seconds:

| Lane | Passing legs | Wall seconds | Seconds excluding input-lock waits | Budget |
|---|---:|---:|---:|---:|
| mac | 477 | 1,102 | 677 | 1,100 |
| linux | 775 | 1,398 | 849 | 1,250 |
| windows | 282 | 1,418 | 1,289 | 1,350 |
| iOS | 139 | 1,328 | 800 | 1,150 |
| Android | 148 | 1,285 | 863 | 870 |

All 1,821 legs passed, and the matrix's gate sweep passed 61/61 in 206
seconds. No red leg or duration-budget failure occurred. Android's longer
first suite was inspected during the run: about 204 seconds of input-lock
waits, drag traces reporting host load above 300, and a contemporaneous
process sample showing simulator services and Spotlight consuming CPU.
Linux rebuilt its core in 262 seconds against the previous matrix's
five-second incremental build. No budget or test was relaxed.

The ledger entry is closed. No new deferred work was opened by this slice.

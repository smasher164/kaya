import { pathToFileURL } from "node:url";
import { performance } from "node:perf_hooks";

const w = await import(process.argv[2]
  ? pathToFileURL(process.argv[2])
  : new URL("../../bindings/js/kaya/wire.ts", import.meta.url));
let sink = 0;

function batch(n) {
  const records = [];
  for (let i = 0; i < n; i++) {
    records.push(w.tx_collection_insert(1, [], new w.I64(i), 0,
      ["AAPL", "Brokerage", i * 1.5, 195.25, "row " + i]));
  }
  sink += records.reduce((n, r) => n + r.length, 0);
  return records;
}

for (let i = 0; i < 100; i++) batch(200);
for (const [n, loops] of [[15003, 1], [20, 1000]]) {
  const times = [];
  for (let i = 0; i < 40; i++) {
    const start = performance.now();
    for (let j = 0; j < loops; j++) batch(n);
    times.push((performance.now() - start) / loops);
  }
  times.sort((a, b) => a - b);
  console.log(JSON.stringify({
    node: process.version, records: n,
    bytes: batch(n).reduce((n, r) => n + r.length, 0),
    best_ms: times[0], median_ms: times[20], samples: 40, loops,
  }));
}
if (!sink) throw Error("no bytes");

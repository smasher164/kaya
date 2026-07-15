// One module for the in-tree Go code: the bindings package
// (dev.kaya/bindings/go) and the example that imports it. The Windows
// VM deploy mirrors this shape (go.mod at C:\kaya, bindings\go below
// it), so the same import path resolves in both places.
module dev.kaya

go 1.22

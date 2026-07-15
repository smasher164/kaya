// The milestone-2 scene from Swift over the C ABI (function floor). The
// kaya declarations come straight from kaya.h via -import-objc-header;
// nothing is re-declared here.
//
// Swift's main thread enters kaya_run() and becomes the core's UI thread;
// a Thread is the app thread, draining occurrences and answering with
// packed transaction records through kaya_submit. The scene declares a
// When (the extras banner) and a nested For (groups holding items);
// clicks on stamped remove buttons come back as a template node id plus
// key path, and the app answers by removing that entry.

import Foundation

// Guest-allocated ids, counted from 1 per space.
let sigStatus: UInt64 = 1
let sigExtras: UInt64 = 2
let wColumn: UInt64 = 1
let wStep: UInt64 = 2
let wStatus: UInt64 = 3
let wWhen: UInt64 = 4
let wGroups: UInt64 = 5
let cGroups: UInt64 = 1
let cItems: UInt64 = 2
let nBanner: UInt64 = 1
let nGroupCol: UInt64 = 2
let nGroupLbl: UInt64 = 3
let nItemsFor: UInt64 = 4
let nItemRow: UInt64 = 5
let nItemText: UInt64 = 6
let nRemove: UInt64 = 7

// --- Transaction packing (KAYA_TX_* layouts from kaya.h) ---------------

struct Tx {
    var bytes = Data()

    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }

    mutating func pad() {
        while bytes.count % 8 != 0 { bytes.append(0) }
    }

    /// Start a record: {u32 size, u16 kind, u16 flags}; the body follows.
    /// Returns the record's start for finish().
    mutating func record(_ kind: UInt16) -> Int {
        let start = bytes.count
        u32(0)
        u16(kind)
        u16(0)
        return start
    }

    // Values are self-padded to 8: they concatenate inside record bodies.
    mutating func str(_ s: String) {
        let utf8 = Array(s.utf8)
        u32(UInt32(KAYA_VALUE_STR))
        u32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
        pad()
    }

    mutating func bool(_ v: Bool) {
        u32(UInt32(KAYA_VALUE_BOOL))
        u32(1)
        bytes.append(v ? 1 : 0)
        pad()
    }

    /// A key path: {u32 count, u32 reserved, count values}.
    mutating func path(_ keys: [String]) {
        u32(UInt32(keys.count))
        u32(0)
        for key in keys { str(key) }
    }

    mutating func finish(_ start: Int) {
        pad()
        let size = UInt32(bytes.count - start).littleEndian
        withUnsafeBytes(of: size) { bytes.replaceSubrange(start..<start + 4, with: $0) }
    }

    mutating func widget(_ id: UInt64, _ kind: UInt32) {
        let s = record(UInt16(KAYA_TX_CREATE_WIDGET))
        u64(id)
        u32(kind)
        u32(0)
        finish(s)
    }

    mutating func textConst(_ id: UInt64, _ text: String) {
        let s = record(UInt16(KAYA_TX_SET_PROPERTY))
        u64(id)
        u32(UInt32(KAYA_PROP_TEXT))
        u32(UInt32(KAYA_SOURCE_CONST))
        str(text)
        finish(s)
    }

    mutating func textElement(_ id: UInt64, _ level: UInt32) {
        let s = record(UInt16(KAYA_TX_SET_PROPERTY))
        u64(id)
        u32(UInt32(KAYA_PROP_TEXT))
        u32(UInt32(KAYA_SOURCE_ELEMENT))
        u32(level)
        u32(0)
        finish(s)
    }

    mutating func twoU64(_ kind: UInt16, _ a: UInt64, _ b: UInt64) {
        let s = record(kind)
        u64(a)
        u64(b)
        finish(s)
    }

    mutating func collection(_ id: UInt64) {
        let s = record(UInt16(KAYA_TX_CREATE_COLLECTION))
        u64(id)
        finish(s)
    }

    mutating func templateEnd() {
        let s = record(UInt16(KAYA_TX_TEMPLATE_END))
        finish(s)
    }

    mutating func insert(_ coll: UInt64, _ at: [String], _ key: String, _ value: String) {
        let s = record(UInt16(KAYA_TX_COLLECTION_INSERT))
        u64(coll)
        path(at)
        str(key)
        str(value)
        finish(s)
    }

    mutating func update(_ coll: UInt64, _ at: [String], _ key: String, _ value: String) {
        let s = record(UInt16(KAYA_TX_COLLECTION_UPDATE))
        u64(coll)
        path(at)
        str(key)
        str(value)
        finish(s)
    }

    mutating func remove(_ coll: UInt64, _ at: [String], _ key: String) {
        let s = record(UInt16(KAYA_TX_COLLECTION_REMOVE))
        u64(coll)
        path(at)
        str(key)
        finish(s)
    }

    mutating func writeStr(_ sig: UInt64, _ text: String) {
        let s = record(UInt16(KAYA_TX_WRITE_SIGNAL))
        u64(sig)
        str(text)
        finish(s)
    }

    mutating func writeBool(_ sig: UInt64, _ v: Bool) {
        let s = record(UInt16(KAYA_TX_WRITE_SIGNAL))
        u64(sig)
        bool(v)
        finish(s)
    }

    func submit() {
        bytes.withUnsafeBytes { raw in
            kaya_submit(raw.bindMemory(to: UInt8.self).baseAddress, UInt(raw.count))
        }
    }
}

func sceneTx() {
    var tx = Tx()
    var s: Int

    s = tx.record(UInt16(KAYA_TX_CREATE_SIGNAL))
    tx.u64(sigStatus)
    tx.str("step 0")
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_CREATE_SIGNAL))
    tx.u64(sigExtras)
    tx.bool(false)
    tx.finish(s)

    tx.widget(wColumn, UInt32(KAYA_KIND_COLUMN))
    tx.widget(wStep, UInt32(KAYA_KIND_BUTTON))
    tx.textConst(wStep, "step")
    tx.widget(wStatus, UInt32(KAYA_KIND_LABEL))

    s = tx.record(UInt16(KAYA_TX_SET_PROPERTY))
    tx.u64(wStatus)
    tx.u32(UInt32(KAYA_PROP_TEXT))
    tx.u32(UInt32(KAYA_SOURCE_SIGNAL))
    tx.u64(sigStatus)
    tx.finish(s)

    // When(extras): a banner label. The scope brackets the blueprint.
    tx.twoU64(UInt16(KAYA_TX_CREATE_WHEN), wWhen, sigExtras)
    tx.widget(nBanner, UInt32(KAYA_KIND_LABEL))
    tx.textConst(nBanner, "extras on")
    tx.templateEnd()

    // For over groups, nesting a For over items.
    tx.collection(cGroups)
    tx.twoU64(UInt16(KAYA_TX_CREATE_FOR), wGroups, cGroups)
    tx.widget(nGroupCol, UInt32(KAYA_KIND_COLUMN))
    tx.widget(nGroupLbl, UInt32(KAYA_KIND_LABEL))
    tx.textElement(nGroupLbl, 0)
    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), nGroupCol, nGroupLbl)
    tx.collection(cItems)
    tx.twoU64(UInt16(KAYA_TX_CREATE_FOR), nItemsFor, cItems)
    tx.widget(nItemRow, UInt32(KAYA_KIND_COLUMN))
    tx.widget(nItemText, UInt32(KAYA_KIND_LABEL))
    tx.textElement(nItemText, 0)
    tx.widget(nRemove, UInt32(KAYA_KIND_BUTTON))
    tx.textConst(nRemove, "remove")
    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), nItemRow, nItemText)
    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), nItemRow, nRemove)
    tx.templateEnd()
    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), nGroupCol, nItemsFor)
    tx.templateEnd()

    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), wColumn, wStep)
    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), wColumn, wStatus)
    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), wColumn, wWhen)
    tx.twoU64(UInt16(KAYA_TX_ADD_CHILD), wColumn, wGroups)
    tx.twoU64(UInt16(KAYA_TX_MOUNT), 0, wColumn) // window 0: the default

    tx.submit()
}

/// One click record: header, u64 id, u32 path_len, u32 pad, values.
func parseClick(_ buf: [UInt8]) -> (id: UInt64, keys: [String])? {
    let kind = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
    guard kind == UInt16(KAYA_OCCURRENCE_BUTTON_CLICKED) else { return nil }
    return buf.withUnsafeBytes { raw in
        let id = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        let pathLen = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        var keys: [String] = []
        var at = 24
        for _ in 0..<pathLen {
            let vlen = Int(raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            keys.append(String(decoding: raw[(at + 8)..<(at + 8 + vlen)], as: UTF8.self))
            at += 8 + ((vlen + 7) & ~7)
        }
        return (id, keys)
    }
}

let appThread = Thread {
    sceneTx()
    var steps = 0
    var buf = [UInt8](repeating: 0, count: 256)
    while true {
        let size = buf.withUnsafeMutableBufferPointer { p in
            kaya_next_occurrence(p.baseAddress, 256)
        }
        if size == 0 { break } // shutdown
        guard let (id, keys) = parseClick(buf) else { continue }
        if keys.isEmpty && id == wStep {
            steps += 1
            var tx = Tx()
            if steps == 1 {
                tx.insert(cGroups, [], "g1", "Work")
                tx.insert(cItems, ["g1"], "a", "send report")
                tx.insert(cItems, ["g1"], "b", "buy milk")
            } else if steps == 2 {
                tx.insert(cGroups, [], "g2", "Home")
                tx.insert(cItems, ["g2"], "a", "water plants")
                tx.update(cGroups, [], "g1", "Office")
            }
            tx.writeBool(sigExtras, steps == 1)
            tx.writeStr(sigStatus, "step \(steps)")
            tx.submit()
        } else if keys.count == 2 && id == nRemove {
            var tx = Tx()
            tx.remove(cItems, [keys[0]], keys[1])
            tx.writeStr(sigStatus, "removed \(keys[0])/\(keys[1])")
            tx.submit()
        }
    }
}
appThread.start()

// Takes over the main thread; on iOS this never returns (the self-test
// exits the process).
exit(kaya_run())

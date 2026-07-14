// Milestone 1 from Swift over the C ABI (function floor). The kaya
// declarations come straight from kaya.h via -import-objc-header; nothing
// is re-declared here.
//
// Swift's main thread enters kaya_run() and becomes the core's UI thread;
// a Thread is the app thread, draining occurrences and answering with
// packed transaction records through kaya_submit. The scene arrives as
// one transaction; the label's text is a signal binding this guest
// writes on every click.

import Foundation

// Guest-allocated ids, counted from 1 per space.
let sigText: UInt64 = 1
let wColumn: UInt64 = 1
let wButton: UInt64 = 2
let wLabel: UInt64 = 3

// --- Transaction packing (KAYA_TX_* layouts from kaya.h) ---------------

struct Tx {
    var bytes = Data()

    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }

    /// Start a record: {u32 size, u16 kind, u16 flags}; the body follows.
    /// Returns the record's start for finish().
    mutating func record(_ kind: UInt16) -> Int {
        let start = bytes.count
        u32(0)
        u16(kind)
        u16(0)
        return start
    }

    mutating func str(_ s: String) {
        let utf8 = Array(s.utf8)
        u32(UInt32(KAYA_VALUE_STR))
        u32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func finish(_ start: Int) {
        while bytes.count % 8 != 0 { bytes.append(0) }
        let size = UInt32(bytes.count - start).littleEndian
        withUnsafeBytes(of: size) { bytes.replaceSubrange(start..<start + 4, with: $0) }
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
    tx.u64(sigText)
    tx.str("Clicked 0 times")
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_CREATE_WIDGET))
    tx.u64(wColumn)
    tx.u32(UInt32(KAYA_KIND_COLUMN))
    tx.u32(0)
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_CREATE_WIDGET))
    tx.u64(wButton)
    tx.u32(UInt32(KAYA_KIND_BUTTON))
    tx.u32(0)
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_SET_PROPERTY))
    tx.u64(wButton)
    tx.u32(UInt32(KAYA_PROP_TEXT))
    tx.u32(UInt32(KAYA_SOURCE_CONST))
    tx.str("Click me")
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_CREATE_WIDGET))
    tx.u64(wLabel)
    tx.u32(UInt32(KAYA_KIND_LABEL))
    tx.u32(0)
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_SET_PROPERTY))
    tx.u64(wLabel)
    tx.u32(UInt32(KAYA_PROP_TEXT))
    tx.u32(UInt32(KAYA_SOURCE_SIGNAL))
    tx.u64(sigText)
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_ADD_CHILD))
    tx.u64(wColumn)
    tx.u64(wButton)
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_ADD_CHILD))
    tx.u64(wColumn)
    tx.u64(wLabel)
    tx.finish(s)

    s = tx.record(UInt16(KAYA_TX_MOUNT))
    tx.u64(0) // window 0: the default
    tx.u64(wColumn)
    tx.finish(s)

    tx.submit()
}

func writeTx(_ text: String) {
    var tx = Tx()
    let s = tx.record(UInt16(KAYA_TX_WRITE_SIGNAL))
    tx.u64(sigText)
    tx.str(text)
    tx.finish(s)
    tx.submit()
}

let appThread = Thread {
    sceneTx()
    var occurrence = KayaOccurrence()
    var count = 0
    while kaya_next_occurrence(&occurrence) {
        if occurrence.kind == UInt16(KAYA_OCCURRENCE_BUTTON_CLICKED) {
            count += 1
            let noun = count == 1 ? "time" : "times"
            writeTx("Clicked \(count) \(noun)")
        }
    }
}
appThread.start()

// Takes over the main thread; on iOS this never returns (the self-test
// exits the process).
exit(kaya_run())

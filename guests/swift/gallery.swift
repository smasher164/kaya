// The gallery scene from Swift: a row container laying a checkbox and
// the status label side by side. The box owns its checked bit and
// reports each flip through onToggle; the app answers by writing the
// status signal — the same uncontrolled contract as the entry, with a
// bool.

import Foundation

let app = KayaApp()

let (status, urgent) = app.build { tx -> (KayaSignal, KayaWidget) in
    let status = tx.signal(.str("urgent: false"))

    let column = tx.widget(UInt32(KAYA_KIND_COLUMN))
    let row = tx.widget(UInt32(KAYA_KIND_ROW))
    let urgent = tx.widget(UInt32(KAYA_KIND_CHECKBOX))
    tx.setText(urgent, "urgent")
    let statusLabel = tx.widget(UInt32(KAYA_KIND_LABEL))
    tx.bindText(statusLabel, status)

    tx.addChild(row, urgent)
    tx.addChild(row, statusLabel)
    tx.addChild(column, row)
    tx.mount(column)
    return (status, urgent)
}

app.onToggle(urgent) { tx, checked in
    tx.write(status, .str("urgent: \(checked)"))
}

app.run()

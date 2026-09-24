// The format scene, Swift port — guests/rust/format.rs, tools/scenes/format.steps
// (and formatde, formatar through KAYA_LOCALE).

import Foundation
import Kaya

KayaApp.run { app in
    KayaApp.catalog("format")
    let d = KayaDate(year: 2026, month: 9, day: 7)
    let t = KayaTime(hour: 8, minute: 30)
    app.build { tx in
        tx.window(title: "format", width: 540, height: 560)
        let root = tx.column { root in
            tx.label(bind: tx.signal(.str(KayaApp.fmt.date(d, .short))))  // label#0
            tx.label(bind: tx.signal(.str(KayaApp.fmt.date(d, .medium))))  // label#1
            tx.label(bind: tx.signal(.str(KayaApp.fmt.date(d, .long))))  // label#2
            tx.label(bind: tx.signal(.str(KayaApp.fmt.time(t, .short))))  // label#3
            tx.label(bind: tx.signal(.str(KayaApp.fmt.dateTime(d, t, .medium))))  // label#4
            tx.label(bind: tx.signal(.str(KayaApp.fmt.number(1234567.891))))  // label#5
            tx.label(bind: tx.signal(.str(KayaApp.fmt.percent(0.256))))  // label#6
            tx.label(bind: tx.signal(.str(KayaApp.fmt.currency(1234567.89, "USD"))))  // label#7
            tx.label(bind: tx.signal(.str(KayaApp.tr("items", ["count": 1]))))  // label#8
            tx.label(bind: tx.signal(.str(KayaApp.tr("items", ["count": 3]))))  // label#9
            tx.label(bind: tx.signal(.str(KayaApp.tr("greeting", ["name": "Ada"]))))  // label#10
            tx.row { _ in
                tx.label(bind: tx.signal(.str("first")))  // label#11
                tx.spacer()
                tx.label(bind: tx.signal(.str("last")))  // label#12
            }  // row#0
            tx.label(bind: tx.signal(.str(KayaApp.fmt.locale().tag)))  // label#13
            return root
        }
        tx.mount(root)
    }
}

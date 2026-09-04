// The pickers scene, Swift port — guests/rust/pickers.rs,
// tools/scenes/pickers.steps, docs/datetime-plan.md.

import Foundation

struct Task: KayaGen {
    var name: String
    var due: KayaDate
}

func day(_ d: KayaDate) -> String {
    String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
}

func clock(_ t: KayaTime) -> String {
    String(format: "%02d:%02d", t.hour!, t.minute!)
}

let app = KayaApp()

app.build { tx in
    let dateText = tx.signal(.str("date: none"))
    let timeText = tx.signal(.str("time: none"))
    let rowText = tx.signal(.str("row: none"))
    let dateSig = tx.signal(.date(KayaDate(year: 2026, month: 9, day: 4)))
    let timeSig = tx.signal(.time(KayaTime(hour: 14, minute: 30)))
    let tasks = taskCollection(tx)

    let root = tx.column {
        tx.label(bind: dateText)  // label#0
        tx.label(bind: timeText)  // label#1
        tx.label(bind: rowText)  // label#2
        let when = tx.datePicker(
            min: KayaDate(year: 2026, month: 1, day: 1),
            max: KayaDate(year: 2026, month: 12, day: 31),
            bind: dateSig,
            onDate: { tx, picked in tx.write(dateText, .str("date: \(day(picked))")) })
        tx.setA11yId(when, "when")
        tx.setA11yLabel(when, "Due")
        let at = tx.timePicker(
            step: 15, bind: timeSig,
            onTime: { tx, picked in tx.write(timeText, .str("time: \(clock(picked))")) })
        tx.setA11yId(at, "at")
        tx.setA11yLabel(at, "At")
        tx.button("reset") { tx in  // button#0
            tx.write(dateSig, .date(KayaDate(year: 2026, month: 3, day: 1)))
            tx.write(timeSig, .time(KayaTime(hour: 9, minute: 0)))
        }
        for row in tasks.rows {
            row.label(row.name)
            let picker = row.datePicker(row.due) { tx, keys, picked in
                guard case .str(let key) = keys[0] else { return }
                tx.write(rowText, .str("row \(key): \(day(picked))"))
            }
            row.t.setA11yId(picker, "due")
        }
    }
    tx.mount(root)

    tasks.insert(tx, .str("a"), Task(name: "a", due: KayaDate(year: 2026, month: 10, day: 1)))
    tasks.insert(tx, .str("b"), Task(name: "b", due: KayaDate(year: 2026, month: 11, day: 20)))
}

app.run()

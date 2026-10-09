// The segmented control scene, Swift port — guests/rust/segmented.rs,
// tools/scenes/segmented.steps, docs/segmented-plan.md §5.

import Foundation
import Kaya

struct Habit: KayaGen {
    var name: String
    var cadence: Double
}

let periods = ["Day", "Week", "Month"]
let cadences = ["Daily", "Weekly"]

KayaApp.run { app in
    let views: [(String, KayaSymbol)] = [("Info", .info), ("Edit", .edit)]
    var heard = 0

    app.build { tx in
        tx.window(title: "segmented")
        let period = tx.signal(.f64(0.0))
        let periodText = tx.signal(.str("period: Day"))
        let heardText = tx.signal(.str("heard: 0"))
        let viewText = tx.signal(.str("view: Edit"))
        let cadenceText = tx.signal(.str("cadence: -"))
        let habits = habitCollection(tx)

        let root = tx.column { root in
            let seg = tx.segmented(periods, selected: period) { tx, index in
                heard += 1
                tx.write(period, .f64(Double(index)))
                tx.write(periodText, .str("period: \(periods[index])"))
                tx.write(heardText, .str("heard: \(heard)"))
            }
            tx.setA11yId(seg, "period")
            tx.setA11yLabel(seg, "Period")
            tx.label(bind: periodText)
            tx.label(bind: heardText)
            let reset = tx.button("Reset") { tx in
                tx.write(period, .f64(0.0))
                tx.write(periodText, .str("period: Day"))
            }
            tx.setA11yId(reset, "reset")
            let view = tx.segmentedSymbols(views, selected: 1) { tx, index in
                tx.write(viewText, .str("view: \(views[index].0)"))
            }
            tx.setA11yId(view, "view")
            tx.setA11yLabel(view, "View")
            tx.label(bind: viewText)
            tx.label(bind: cadenceText)
            for row in habits.rows {
                row.label(row.name)
                let cadence = row.segmented(cadences, selected: row.cadence) { tx, keys, index in
                    guard case .str(let key) = keys[0] else { return }
                    tx.write(cadenceText, .str("cadence \(key): \(cadences[index])"))
                }
                row.t.setA11yId(cadence, "cadence")
            }
            return root
        }
        tx.mount(root)

        habits.insert(tx, .str("read"), Habit(name: "read", cadence: 1.0))
        habits.insert(tx, .str("walk"), Habit(name: "walk", cadence: 0.0))
    }
}

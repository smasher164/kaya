// The expander scene, Swift port — guests/rust/expander.rs,
// tools/scenes/expander.steps, docs/expander-plan.md §5.

import Foundation
import Kaya

struct Section: KayaGen {
    var name: String
    var open: Bool
}

func word(_ open: Bool) -> String { open ? "open" : "closed" }

KayaApp.run { app in
    var heard = 0
    var opens: [String: Bool] = ["s01": true]

    app.build { tx in
        tx.window(title: "expander", width: 520, height: 860)
        let state = tx.signal(.str("details: closed"))
        let heardText = tx.signal(.str("heard: 0"))
        let typed = tx.signal(.str("name: -"))
        let rowsText = tx.signal(.str("rows: -"))
        let inside = tx.signal(.str("Inside the body"))
        let sections = sectionCollection(tx)

        let root = tx.column { root in
            let details = tx.expander(
                "Details", summary: "One field", symbol: .info,
                onToggle: { tx, open in
                    heard += 1
                    tx.write(state, .str("details: \(word(open))"))
                    tx.write(heardText, .str("heard: \(heard)"))
                }
            ) { details in
                let name = tx.entry(onChange: { tx, text in tx.write(typed, .str("name: \(text)")) })
                tx.setPlaceholder(name, "Name")
                tx.setA11yId(name, "name")
                tx.setA11yId(tx.label(bind: inside), "inside")
                return details
            }
            tx.setA11yId(details, "details")
            tx.setA11yId(tx.label(bind: state), "state")
            tx.setA11yId(tx.label(bind: heardText), "heard")
            tx.setA11yId(tx.label(bind: typed), "typed")
            tx.row { _ in
                tx.setA11yId(tx.button("Show") { tx in
                    tx.setExpanded(details, true)
                    tx.write(state, .str("details: open"))
                }, "show")
                tx.setA11yId(tx.button("Hide") { tx in
                    tx.setExpanded(details, false)
                    tx.write(state, .str("details: closed"))
                }, "hide")
            }
            tx.column { form in
                tx.setA11yId(form, "form")
                tx.labeled("Sort") { _ in
                    tx.setA11yId(tx.select(["Due", "Name"]), "sort")
                }
                tx.expander("Advanced") { advanced in
                    tx.setA11yId(advanced, "advanced")
                    tx.labeled("Hide badge") { _ in
                        tx.setA11yId(tx.checkbox(""), "badge")
                    }
                    tx.labeled("Keep completed") { _ in
                        tx.setA11yId(tx.checkbox(""), "keep")
                    }
                }
            }
            tx.setA11yId(tx.label(bind: rowsText), "rows")
            tx.setA11yId(tx.button("Rebuild") { tx in
                sections.remove(tx, .str("s00"))
                sections.insert(tx, .str("s00"), Section(name: "Section 0", open: opens["s00"] ?? false))
                tx.write(rowsText, .str("rebuilt s00"))
            }, "rebuild")
            tx.column { _ in
                for row in sections.rows {
                    let node = row.expander(row.name, expanded: row.open, onToggle: { tx, keys, open in
                        guard case .str(let key) = keys[0] else { return }
                        opens[key] = open
                        sections.patch(tx, keys[0]).set(\.open, open)
                        tx.write(rowsText, .str("sec \(key): \(word(open))"))
                    }) {
                        row.label(row.name)
                    }
                    row.t.setA11yId(node, "sec")
                }
            }
            return root
        }
        tx.mount(root)

        for i in 0..<3 {
            sections.insert(tx, .str("s0\(i)"), Section(name: "Section \(i)", open: i == 1))
        }
    }
}

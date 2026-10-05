import Foundation
import Kaya

struct TimecodeLine: KayaGen {
    var qty: Double
}

KayaApp.run { app in
    let normal = KayaTimecodeRate(25)
    let drop = KayaTimecodeRate(30000, 1001, drop: true)
    var commits = 0
    var phase = 0
    precondition(KayaFmt.parseTimecode("٠١:٠٢:٠٣:١٢", normal) == 93087)
    precondition(KayaFmt.parseTimecode("00:01:00;00", drop) == nil)
    precondition(KayaFmt.parseTimecode("00:00:00:00\0ignored", normal) == nil)
    app.build { tx in
        tx.window(title: "Timecode", width: 440, height: 500)
        let status = tx.signal(.str("commits: 0"))
        let rowStatus = tx.signal(.str("row: none"))
        let playhead = tx.signal(.str(KayaFmt.timecode(93087, normal)))
        let rows = timecodeLineCollection(tx)
        let switchingValue = tx.signal(.f64(-2))
        let committed: (KayaAppTx, Double) -> Void = { tx, frames in
            commits += 1
            tx.write(status, .str("commits: \(commits)"))
            tx.write(playhead, .str(KayaFmt.timecode(Int64(frames), normal)))
        }
        let root = tx.column { root in
            tx.label("25 fps")
            tx.setA11yId(tx.label(bind: playhead), "playhead")
            let field = tx.numberField(value: 93087, format: .timecode(normal), onCommit: committed)
            tx.setA11yId(field, "position")
            tx.setA11yLabel(field, "Position")
            tx.setA11yId(tx.label(bind: status), "commits")
            tx.label("29.97 drop-frame")
            let dropped = tx.numberField(value: 1799, format: .timecode(drop), onCommit: committed)
            tx.setA11yId(dropped, "drop")
            tx.setA11yLabel(dropped, "Drop frame")
            tx.setA11yId(tx.entry(), "note")
            for row in rows.rows {
                let field = row.numberField(value: row.qty, format: .timecode(normal), onCommit: { tx, keys, frames in
                    guard case .str(let key) = keys[0] else { return }
                    tx.write(rowStatus, .str("row \(key): \(Int64(frames))"))
                })
                row.t.setA11yId(field, "rowtime")
            }
            tx.setA11yId(tx.label(bind: rowStatus), "row")
            let switching = tx.numberField(bind: switchingValue)
            tx.setA11yId(switching, "switching")
            let switchFormat = tx.button("Switch format") { tx in
                switch phase % 4 {
                case 0: tx.setFormat(switching, .timecode(drop)); tx.write(switchingValue, .f64(1800))
                case 1: tx.write(switchingValue, .f64(-2)); tx.setFormat(switching, .number)
                case 2: tx.write(switchingValue, .f64(1800)); tx.setFormat(switching, .timecode(drop))
                default: tx.setFormat(switching, .number); tx.write(switchingValue, .f64(-2))
                }
                phase += 1
            }
            tx.setA11yId(switchFormat, "switchformat")
            return root
        }
        tx.mount(root)
        rows.insert(tx, .str("a"), TimecodeLine(qty: 25))
    }
}

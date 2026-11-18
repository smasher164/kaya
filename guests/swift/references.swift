// The references scene, Swift port — guests/rust/references.rs,
// tools/scenes/references.steps (docs/restoration-plan.md SR11, SR12): a
// picked file's durable reference rides the session store across a
// relaunch and redeems for its bytes; a foreign token and a deleted file
// are refused by name.

import Foundation
import Kaya

/// The bytes a token redeems for, or the refusal's branch; the sentence
/// goes to stderr, where the leg log keeps it.
func readBack(_ token: String) -> String {
    do {
        let redeemed = try KayaApp.redeem(token)
        let (file, _) = try redeemed.file.open()
        let data = file.readDataToEndOfFile()
        try? file.close()
        return "redeemed: " + String(decoding: data, as: UTF8.self)
    } catch let refused as KayaReferenceError {
        FileHandle.standardError.write(Data("references: \(refused.message)\n".utf8))
        return refused.refusal
    } catch {
        return "open failed: \(error)"
    }
}

KayaApp.run { app in
    let post = app.post
    #if os(iOS)
        let kayaTmp = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
    #else
        let kayaTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    #endif
    let dir = (kayaTmp as NSString)
        .appendingPathComponent("kaya-refs-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, body) in [("picked.txt", "picked bytes"), ("decoy.txt", "decoy")] {
        try? body.write(
            toFile: (dir as NSString).appendingPathComponent(name), atomically: true,
            encoding: .utf8)
    }

    let session = KayaApp.session()
    let saved = session.get("doc", default: "")

    app.build { tx in
        tx.window(title: "references")
        let status = tx.signal(.str(saved.isEmpty ? "no reference" : "redeeming"))
        let receive: @KayaAppActor @Sendable (KayaAppTx, String) -> Void = { tx, text in
            tx.write(status, .str(text))
        }
        func reader(_ token: String) {
            Thread.detachNewThread {
                let said = readBack(token)
                post { tx in receive(tx, said) }
            }
        }
        func picked(_ tx: KayaAppTx, _ files: [KayaPickedFile]) {
            guard let file = files.first else {
                tx.write(status, .str("cancelled"))
                return
            }
            do {
                session.set("doc", try file.reference())
                session.set("dir", dir)
                tx.write(status, .str("minted"))
            } catch let refused as KayaReferenceError {
                FileHandle.standardError.write(Data("references: \(refused.message)\n".utf8))
                tx.write(status, .str(refused.refusal))
            } catch {
                tx.write(status, .str("mint failed: \(error)"))
            }
        }

        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: status), "status")
            tx.setA11yId(
                tx.button("pick", onClick: { _ in
                    app.task {
                        let files = await app.pickFile(filters: [("Text", "txt")])
                        app.build { tx in picked(tx, files) }
                    }
                }), "pick")
            tx.setA11yId(
                tx.button("foreign", onClick: { _ in reader("kaya-ref1:beos:AAAA:00000000") }),
                "foreign")
            tx.setA11yId(
                tx.button("delete", onClick: { _ in
                    let folder = session.get("dir", default: "")
                    try? FileManager.default.removeItem(
                        atPath: (folder as NSString).appendingPathComponent("picked.txt"))
                    reader(saved)
                }), "delete")
            return root
        }
        tx.mount(root)
        if !saved.isEmpty {
            reader(saved)
        }
    }
}

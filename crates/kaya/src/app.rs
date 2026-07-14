//! The app thread's view of the world: occurrences in, commands out.

use std::sync::mpsc::{Receiver, Sender};

use crate::protocol::{Command, Occurrence};

pub struct AppCtx {
    pub(crate) occurrences: Receiver<Occurrence>,
    pub(crate) commands: Sender<Command>,
}

impl AppCtx {
    /// Block until the next occurrence arrives. A disconnected channel
    /// means the core is shutting down, which is an occurrence, not an
    /// error.
    pub fn next(&self) -> Occurrence {
        self.occurrences.recv().unwrap_or(Occurrence::Shutdown)
    }

    /// Queue a command and wake the main loop to apply it.
    pub fn send(&self, command: Command) {
        if self.commands.send(command).is_ok() {
            #[cfg(any(target_os = "macos", target_os = "windows"))]
            crate::backend::ring_doorbell();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;

    use super::AppCtx;
    use crate::protocol::{Command, Occurrence, WidgetId};

    /// The round trip minus AppKit: an occurrence reaches the app thread,
    /// and the handler's command comes back on the command channel.
    #[test]
    fn occurrence_to_command_round_trip() {
        let (occ_tx, occ_rx) = mpsc::channel();
        let (cmd_tx, cmd_rx) = mpsc::channel();
        let ctx = AppCtx {
            occurrences: occ_rx,
            commands: cmd_tx,
        };

        let app = std::thread::spawn(move || {
            let mut count = 0u64;
            loop {
                match ctx.next() {
                    Occurrence::ButtonClicked { .. } => {
                        count += 1;
                        ctx.send(Command::SetText {
                            id: WidgetId(2),
                            text: format!("Clicked {count} times"),
                        });
                    }
                    Occurrence::Shutdown => break,
                }
            }
        });

        occ_tx.send(Occurrence::ButtonClicked { id: WidgetId(1) }).unwrap();
        occ_tx.send(Occurrence::ButtonClicked { id: WidgetId(1) }).unwrap();

        let first = cmd_rx.recv().unwrap();
        let second = cmd_rx.recv().unwrap();
        match (first, second) {
            (Command::SetText { text: a, .. }, Command::SetText { text: b, .. }) => {
                assert_eq!(a, "Clicked 1 times");
                assert_eq!(b, "Clicked 2 times");
            }
        }

        drop(occ_tx);
        app.join().unwrap();
    }
}

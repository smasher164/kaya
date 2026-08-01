//! The occurrence ring: byte records in shared memory, written by the core
//! on the main thread, readable lock-free by any consumer with atomics.
//!
//! This is the first piece of the real transport. Records follow the
//! design document's header layout (u32 size, u16 kind, u16 flags, 8-byte
//! aligned, payload inline). The consumer contract, io_uring style:
//!
//! 1. Load `tail` with acquire ordering. If `head == tail`, the ring is
//!    empty; call `kaya_wait_occurrences` to block (function calls are
//!    for waiting, never for the data path).
//! 2. Read the record at `head & (capacity - 1)`. Skip PAD records.
//! 3. Advance `head` by the record size with a release store.
//!
//! Capacity is fixed for now; a full ring is a loud failure. Chained
//! segment growth arrives with the full protocol.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex};

pub const REC_PAD: u16 = 0;
pub const REC_BUTTON_CLICKED: u16 = 1;
pub const REC_TEXT_CHANGED: u16 = 2;
pub const REC_TOGGLED: u16 = 3;
pub const REC_VALUE_CHANGED: u16 = 4;
pub const REC_CLOSE_REQUESTED: u16 = 5;
pub const REC_WINDOW_CLOSED: u16 = 6;
pub const REC_ALERT_RESULT: u16 = 7;
pub const REC_ENTRY_POPPED: u16 = 8;
pub const REC_BACK_REQUESTED: u16 = 9;
pub const REC_SECTION_SELECTED: u16 = 10;
// Menu occurrences. Each carries the button_clicked body shape — u64
// item id, u32 path_len, u32 reserved, then path_len key values (the
// on_click_node encoding: empty for a bar/live-widget activation, the
// anchor copy's key path for a node-anchored context item) — then the
// payload for the stateful pair (a Bool for toggled, an F64 index for
// value_changed).
pub const REC_MENU_ACTIVATED: u16 = 11;
pub const REC_MENU_TOGGLED: u16 = 12;
pub const REC_MENU_VALUE_CHANGED: u16 = 13;
/// The picker's one answer: `count` files, each three consecutive
/// values — I64 handle, Str name, Str local_path. Cancel is count zero.
pub const REC_FILE_DIALOG_RESULT: u16 = 14;

/// Wire framing of every record, exported through the C header so direct
/// consumers cast a pointer instead of bit-twiddling. Little-endian
/// layout; records are 8-byte aligned, so the payload follows the header
/// at natural alignment.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct KayaRecordHeader {
    pub size: u32,
    pub kind: u16,
    pub flags: u16,
}

/// The button-clicked record as it appears on the wire. `id` is a widget
/// id when `path_len` is 0 (a click on a guest-created widget) and a
/// template node id otherwise, with `path_len` key values — the copy's
/// key path, outermost first, each encoded as { u32 type; u32 len;
/// payload padded to 8 } — following the fixed part. Constructed by
/// direct consumers casting into the ring, not by Rust code.
#[allow(dead_code)]
#[repr(C)]
#[derive(Clone, Copy)]
pub struct KayaRecordButtonClicked {
    pub header: KayaRecordHeader,
    pub id: u64,
    pub path_len: u32,
    pub reserved: u32,
}

const HEADER_SIZE: u32 = 8;

#[repr(C, align(64))]
struct Cursor(AtomicU32);

/// What a blocking consumer woke up for.
#[derive(Debug, PartialEq, Eq)]
pub enum Waited {
    /// One occurrence record: kind and body.
    Record(u16, Vec<u8>),
    /// A background thread rang `wake`. Nothing is in the ring; the
    /// consumer has work of its own queued.
    Woken,
    /// The core has shut down and the ring is drained.
    Shutdown,
}

pub struct OccRing {
    head: Cursor,
    tail: Cursor,
    shutdown: AtomicBool,
    // A wake pending for the consumer: the app thread parks here for
    // occurrences, and a guest's background thread may have work for it
    // that is NOT an occurrence — a posted closure. One-shot, consumed
    // by whichever waiter sees it.
    woken: AtomicBool,
    // Consumers inside `cond.wait` right now. This exists so a test can
    // KNOW the consumer is parked before waking it; without it the wake
    // test races and passes whenever the flag happens to be set before
    // the waiter arrives, which proves nothing about the notify.
    parked: AtomicUsize,
    buf: Box<[UnsafeCell<u64>]>,
    waiter: Mutex<()>,
    cond: Condvar,
}

// The buffer is written only by the single producer and read only by the
// single consumer, with ordering established through head/tail.
unsafe impl Send for OccRing {}
unsafe impl Sync for OccRing {}

impl OccRing {
    pub fn new(capacity_bytes: u32) -> Self {
        assert!(capacity_bytes.is_power_of_two());
        assert!(capacity_bytes >= 2 * HEADER_SIZE);
        let qwords = (capacity_bytes / 8) as usize;
        OccRing {
            head: Cursor(AtomicU32::new(0)),
            tail: Cursor(AtomicU32::new(0)),
            shutdown: AtomicBool::new(false),
            woken: AtomicBool::new(false),
            parked: AtomicUsize::new(0),
            buf: (0..qwords).map(|_| UnsafeCell::new(0)).collect(),
            waiter: Mutex::new(()),
            cond: Condvar::new(),
        }
    }

    fn capacity(&self) -> u32 {
        (self.buf.len() * 8) as u32
    }

    fn mask(&self) -> u32 {
        self.capacity() - 1
    }

    fn slot_ptr(&self, byte_offset: u32) -> *mut u64 {
        let index = ((byte_offset & self.mask()) / 8) as usize;
        self.buf[index].get()
    }

    fn write_qword(&self, byte_offset: u32, value: u64) {
        unsafe { *self.slot_ptr(byte_offset) = value };
    }

    fn write_header(&self, byte_offset: u32, header: KayaRecordHeader) {
        unsafe { *(self.slot_ptr(byte_offset) as *mut KayaRecordHeader) = header };
    }

    fn read_header(&self, byte_offset: u32) -> KayaRecordHeader {
        unsafe { *(self.slot_ptr(byte_offset) as *const KayaRecordHeader) }
    }

    fn read_qword(&self, byte_offset: u32) -> u64 {
        unsafe { *self.slot_ptr(byte_offset) }
    }

    /// Producer side. Single producer only. `body` must be 8-aligned in
    /// length (record bodies always are). Panics when full; the design
    /// says never block and never drop, and growth is not built yet.
    pub fn push_record(&self, kind: u16, body: &[u8]) {
        // One occurrence bound for the app thread (crate::stall).
        crate::stall::enqueued();
        if !self.try_push_record(kind, body) {
            panic!("kaya occurrence ring full: segment growth is not implemented yet");
        }
    }

    /// Producer side. Single producer only. Returns false when full.
    pub fn try_push_record(&self, kind: u16, body: &[u8]) -> bool {
        assert!(body.len() % 8 == 0, "kaya: record body not 8-aligned");
        let size = HEADER_SIZE + body.len() as u32;
        assert!(
            size <= self.capacity() / 2,
            "kaya: occurrence record larger than half the ring"
        );
        let mut tail = self.tail.0.load(Ordering::Relaxed);
        let head = self.head.0.load(Ordering::Acquire);

        let until_wrap = self.capacity() - (tail & self.mask());
        let pad = if until_wrap < size { until_wrap } else { 0 };
        let free = self.capacity() - tail.wrapping_sub(head);
        if free < size + pad {
            return false;
        }

        if pad != 0 {
            self.write_header(
                tail,
                KayaRecordHeader {
                    size: pad,
                    kind: REC_PAD,
                    flags: 0,
                },
            );
            tail = tail.wrapping_add(pad);
        }
        self.write_header(tail, KayaRecordHeader { size, kind, flags: 0 });
        for (i, chunk) in body.chunks_exact(8).enumerate() {
            self.write_qword(
                tail.wrapping_add(8 + 8 * i as u32),
                u64::from_le_bytes(chunk.try_into().unwrap()),
            );
        }
        self.tail
            .0
            .store(tail.wrapping_add(size), Ordering::Release);

        {
            let _guard = self.waiter.lock().unwrap();
            self.cond.notify_all();
        }
        true
    }

    /// Consumer side, for in-process consumers (the C function floor).
    /// Foreign consumers with atomics read the ring directly instead.
    /// Single consumer only. `Shutdown` after shutdown drains the ring;
    /// `Woken` when a background thread rang `wake` and the consumer
    /// should look at its OWN queue instead (a posted closure is not an
    /// occurrence and never enters this ring).
    pub fn wait_pop(&self) -> Waited {
        loop {
            let head = self.head.0.load(Ordering::Relaxed);
            let tail = self.tail.0.load(Ordering::Acquire);
            if head != tail {
                let header = self.read_header(head);
                if header.kind == REC_PAD {
                    self.head
                        .0
                        .store(head.wrapping_add(header.size), Ordering::Release);
                    continue;
                }
                let body_len = (header.size - HEADER_SIZE) as usize;
                let mut body = Vec::with_capacity(body_len);
                for i in 0..(body_len / 8) as u32 {
                    body.extend_from_slice(
                        &self.read_qword(head.wrapping_add(8 + 8 * i)).to_le_bytes(),
                    );
                }
                self.head
                    .0
                    .store(head.wrapping_add(header.size), Ordering::Release);
                crate::stall::taken();
                return Waited::Record(header.kind, body);
            }
            if self.shutdown.load(Ordering::Acquire) {
                return Waited::Shutdown;
            }
            if self.woken.swap(false, Ordering::AcqRel) {
                return Waited::Woken;
            }
            let guard = self.waiter.lock().unwrap();
            // Re-check under the lock so a push between the emptiness check
            // and the wait is not a lost wakeup. The wake flag rides the
            // same re-check for the same reason.
            let tail = self.tail.0.load(Ordering::Acquire);
            if tail != self.head.0.load(Ordering::Relaxed)
                || self.shutdown.load(Ordering::Acquire)
                || self.woken.load(Ordering::Acquire)
            {
                continue;
            }
            self.parked.fetch_add(1, Ordering::Release);
            let _guard = self.cond.wait(guard).unwrap();
            self.parked.fetch_sub(1, Ordering::Release);
        }
    }

    /// Block until the ring is non-empty or shut down. Returns true if
    /// records are available. This is the waiting half of the direct-access
    /// contract; the data path never calls a function.
    pub fn wait_nonempty(&self) -> bool {
        loop {
            let head = self.head.0.load(Ordering::Acquire);
            let tail = self.tail.0.load(Ordering::Acquire);
            if head != tail {
                return true;
            }
            if self.shutdown.load(Ordering::Acquire) {
                return false;
            }
            // A wake returns TRUE with the ring still empty. That is not a
            // lie the consumer has to detect: its loop drains its own queue
            // and re-checks, so "there may be something for you" is the
            // whole contract. One extra spin, never a spin loop — the flag
            // is consumed here.
            if self.woken.swap(false, Ordering::AcqRel) {
                return true;
            }
            let guard = self.waiter.lock().unwrap();
            let tail = self.tail.0.load(Ordering::Acquire);
            if tail != self.head.0.load(Ordering::Acquire)
                || self.shutdown.load(Ordering::Acquire)
                || self.woken.load(Ordering::Acquire)
            {
                continue;
            }
            self.parked.fetch_add(1, Ordering::Release);
            let _guard = self.cond.wait(guard).unwrap();
            self.parked.fetch_sub(1, Ordering::Release);
        }
    }

    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
    pub fn set_shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
        let _guard = self.waiter.lock().unwrap();
        self.cond.notify_all();
    }

    /// Wake the parked consumer WITHOUT pushing anything. The app thread
    /// blocks on this ring waiting for occurrences; a guest's background
    /// thread has work for it that is not an occurrence — a closure
    /// posted with App.Post — and this is how that thread says so. Safe
    /// from any thread, unlike the producer side.
    ///
    /// One-shot: whichever waiter sees the flag consumes it and reports
    /// `Woken` (or `true`, on the direct path). Setting it while nobody
    /// is parked is not lost — the next waiter takes it before parking,
    /// which is the same lost-wakeup re-check the push side does.
    pub fn wake(&self) {
        self.woken.store(true, Ordering::Release);
        let _guard = self.waiter.lock().unwrap();
        self.cond.notify_all();
    }

    /// Consumers inside `cond.wait` right now. This is observability for
    /// ONE purpose: a wake test that does not first know the consumer is
    /// parked proves nothing, because the flag is also honored on the way
    /// in. The shutdown test above had exactly that weakness (it slept 50ms)
    /// and now spins on this instead.
    ///
    /// Test-only, and cfg'd rather than allow'd so it says which: a shipped
    /// build has no reason to ask, and a silenced dead-code warning is how
    /// dead machinery survives (the lesson check-detekt exists for).
    #[cfg(test)]
    pub fn parked(&self) -> usize {
        self.parked.load(Ordering::Acquire)
    }

    /// Raw layout for direct consumers, io_uring-offsets style. The
    /// pointers stay valid as long as the ring is alive.
    pub fn raw(&self) -> (*mut u8, u32, *mut u32, *mut u32) {
        (
            self.buf.as_ptr() as *mut u8,
            self.capacity(),
            self.head.0.as_ptr(),
            self.tail.0.as_ptr(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn body(v: u64) -> Vec<u8> {
        v.to_le_bytes().to_vec()
    }

    #[test]
    fn round_trip_one_record() {
        let ring = OccRing::new(64);
        ring.push_record(REC_BUTTON_CLICKED, &body(7));
        assert_eq!(ring.wait_pop(), Waited::Record(REC_BUTTON_CLICKED, body(7)));
    }

    #[test]
    fn round_trip_multi_qword_body() {
        let ring = OccRing::new(128);
        let long: Vec<u8> = (0..32).collect();
        ring.push_record(REC_BUTTON_CLICKED, &long);
        assert_eq!(ring.wait_pop(), Waited::Record(REC_BUTTON_CLICKED, long));
    }

    #[test]
    fn wraps_with_pad_records() {
        // Capacity 64 holds four 16-byte records; pushing and popping many
        // forces wraparound and pad insertion at every misfit boundary.
        let ring = OccRing::new(64);
        for i in 0..1000u64 {
            ring.push_record(REC_BUTTON_CLICKED, &body(i));
            if i % 2 == 0 {
                ring.push_record(REC_BUTTON_CLICKED, &body(i + 1000));
                assert_eq!(ring.wait_pop(), Waited::Record(REC_BUTTON_CLICKED, body(i)));
                assert_eq!(ring.wait_pop(), Waited::Record(REC_BUTTON_CLICKED, body(i + 1000)));
            } else {
                assert_eq!(ring.wait_pop(), Waited::Record(REC_BUTTON_CLICKED, body(i)));
            }
        }
    }

    #[test]
    fn cross_thread_order_and_values() {
        let ring = Arc::new(OccRing::new(1024));
        let producer = {
            let ring = ring.clone();
            std::thread::spawn(move || {
                for i in 0..50_000u64 {
                    while !ring.try_push_record(REC_BUTTON_CLICKED, &body(i)) {
                        std::thread::yield_now();
                    }
                }
                ring.set_shutdown();
            })
        };
        let mut expected = 0u64;
        while let Waited::Record(kind, payload) = ring.wait_pop() {
            assert_eq!(kind, REC_BUTTON_CLICKED);
            assert_eq!(payload, body(expected));
            expected += 1;
        }
        assert_eq!(expected, 50_000);
        producer.join().unwrap();
    }

    #[test]
    fn shutdown_wakes_blocked_consumer() {
        let ring = Arc::new(OccRing::new(64));
        let consumer = {
            let ring = ring.clone();
            std::thread::spawn(move || ring.wait_pop())
        };
        while ring.parked() == 0 {
            std::thread::yield_now();
        }
        ring.set_shutdown();
        assert_eq!(consumer.join().unwrap(), Waited::Shutdown);
    }

    // THE WAKE, and the reason `parked` exists. A background thread rings
    // the doorbell for work that is NOT an occurrence — a posted closure
    // — and the app thread must come back from `cond.wait` for it.
    //
    // Spinning on `parked` first is what makes this a test of the NOTIFY
    // rather than of the flag: the wake is also honored on the way in, so
    // a version that slept and lost the race would pass while proving
    // nothing. The scene cannot make this observation at all, which is
    // why it lives here (docs/background-work-plan.md §5).
    // Wait for a woken consumer WITHOUT joining. A missing notify leaves
    // the consumer parked forever, and `join` would turn that into a hung
    // matrix lane instead of a failure — the worst way for a gate to
    // report. Verified by deleting the notify: this says so in seconds.
    fn woke_within<T: Send + 'static>(
        ring: &Arc<OccRing>,
        wait: impl FnOnce(Arc<OccRing>) -> T + Send + 'static,
    ) -> T {
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let handle = ring.clone();
        std::thread::spawn(move || {
            let _ = done_tx.send(wait(handle));
        });
        while ring.parked() == 0 {
            std::thread::yield_now();
        }
        ring.wake();
        done_rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("wake left the consumer parked: the notify is missing")
    }

    #[test]
    fn wake_returns_a_parked_consumer_with_an_empty_ring() {
        for _ in 0..200 {
            let ring = Arc::new(OccRing::new(64));
            assert_eq!(woke_within(&ring, |r| r.wait_pop()), Waited::Woken);
            // One-shot: the flag was consumed, so the ring is quiet again.
            assert!(!ring.woken.load(Ordering::Acquire));
        }
    }

    // The same for the direct path, whose consumers (Go, C#, Haskell,
    // OCaml) never call wait_pop. A wake there returns TRUE with the ring
    // still empty — deliberately indistinguishable from data, because the
    // consumer's loop drains its own queue and re-checks either way.
    #[test]
    fn wake_returns_a_parked_direct_consumer() {
        for _ in 0..200 {
            let ring = Arc::new(OccRing::new(64));
            assert!(woke_within(&ring, |r| r.wait_nonempty()));
        }
    }

    // A wake set while NOBODY is parked is not lost: the next waiter
    // takes it before parking. Same lost-wakeup re-check the push side
    // does, and the case a naive implementation drops.
    #[test]
    fn wake_before_the_consumer_arrives_is_not_lost() {
        let ring = OccRing::new(64);
        ring.wake();
        assert_eq!(ring.wait_pop(), Waited::Woken);
    }

    #[test]
    #[should_panic(expected = "ring full")]
    fn full_ring_fails_loudly() {
        let ring = OccRing::new(64);
        for i in 0..5 {
            ring.push_record(REC_BUTTON_CLICKED, &body(i));
        }
    }
}

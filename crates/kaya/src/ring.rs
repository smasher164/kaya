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
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Condvar, Mutex};

pub const REC_PAD: u16 = 0;
pub const REC_BUTTON_CLICKED: u16 = 1;

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

/// The button-clicked record as it appears on the wire. Constructed by
/// direct consumers casting into the ring, not by Rust code.
#[allow(dead_code)]
#[repr(C)]
#[derive(Clone, Copy)]
pub struct KayaRecordButtonClicked {
    pub header: KayaRecordHeader,
    pub widget_id: u64,
}

const HEADER_SIZE: u32 = 8;

#[repr(C, align(64))]
struct Cursor(AtomicU32);

pub struct OccRing {
    head: Cursor,
    tail: Cursor,
    shutdown: AtomicBool,
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

    /// Producer side. Single producer only. Panics when full; the design
    /// says never block and never drop, and growth is not built yet.
    pub fn push(&self, kind: u16, payload: u64) {
        if !self.try_push(kind, payload) {
            panic!("kaya occurrence ring full: segment growth is not implemented yet");
        }
    }

    /// Producer side. Single producer only. Returns false when full.
    pub fn try_push(&self, kind: u16, payload: u64) -> bool {
        let size = HEADER_SIZE + 8;
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
        self.write_qword(tail.wrapping_add(8), payload);
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
    /// Single consumer only. Returns None after shutdown drains the ring.
    pub fn wait_pop(&self) -> Option<(u16, u64)> {
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
                let payload = self.read_qword(head.wrapping_add(8));
                self.head
                    .0
                    .store(head.wrapping_add(header.size), Ordering::Release);
                return Some((header.kind, payload));
            }
            if self.shutdown.load(Ordering::Acquire) {
                return None;
            }
            let guard = self.waiter.lock().unwrap();
            // Re-check under the lock so a push between the emptiness check
            // and the wait is not a lost wakeup.
            let tail = self.tail.0.load(Ordering::Acquire);
            if tail != self.head.0.load(Ordering::Relaxed)
                || self.shutdown.load(Ordering::Acquire)
            {
                continue;
            }
            let _guard = self.cond.wait(guard).unwrap();
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
            let guard = self.waiter.lock().unwrap();
            let tail = self.tail.0.load(Ordering::Acquire);
            if tail != self.head.0.load(Ordering::Acquire)
                || self.shutdown.load(Ordering::Acquire)
            {
                continue;
            }
            let _guard = self.cond.wait(guard).unwrap();
        }
    }

    pub fn set_shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
        let _guard = self.waiter.lock().unwrap();
        self.cond.notify_all();
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

    #[test]
    fn round_trip_one_record() {
        let ring = OccRing::new(64);
        ring.push(REC_BUTTON_CLICKED, 7);
        assert_eq!(ring.wait_pop(), Some((REC_BUTTON_CLICKED, 7)));
    }

    #[test]
    fn wraps_with_pad_records() {
        // Capacity 64 holds four 16-byte records; pushing and popping many
        // forces wraparound and pad insertion at every misfit boundary.
        let ring = OccRing::new(64);
        for i in 0..1000u64 {
            ring.push(REC_BUTTON_CLICKED, i);
            if i % 2 == 0 {
                ring.push(REC_BUTTON_CLICKED, i + 1000);
                assert_eq!(ring.wait_pop(), Some((REC_BUTTON_CLICKED, i)));
                assert_eq!(ring.wait_pop(), Some((REC_BUTTON_CLICKED, i + 1000)));
            } else {
                assert_eq!(ring.wait_pop(), Some((REC_BUTTON_CLICKED, i)));
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
                    while !ring.try_push(REC_BUTTON_CLICKED, i) {
                        std::thread::yield_now();
                    }
                }
                ring.set_shutdown();
            })
        };
        let mut expected = 0u64;
        while let Some((kind, payload)) = ring.wait_pop() {
            assert_eq!(kind, REC_BUTTON_CLICKED);
            assert_eq!(payload, expected);
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
        std::thread::sleep(std::time::Duration::from_millis(50));
        ring.set_shutdown();
        assert_eq!(consumer.join().unwrap(), None);
    }

    #[test]
    #[should_panic(expected = "ring full")]
    fn full_ring_fails_loudly() {
        let ring = OccRing::new(64);
        for i in 0..5 {
            ring.push(REC_BUTTON_CLICKED, i);
        }
    }
}

//! A blob's content id (docs/network-images-plan.md N10): equal bytes, equal
//! id, whichever row or signal holds them, so a backend's decoded-picture
//! cache cannot paint the wrong picture under a reused key.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, OnceLock, Weak};

struct Memo {
    by_allocation: HashMap<usize, (Weak<[u8]>, u64)>,
    prune_at: usize,
    hashed: u64,
}

fn memo() -> &'static Mutex<Memo> {
    static MEMO: OnceLock<Mutex<Memo>> = OnceLock::new();
    MEMO.get_or_init(|| Mutex::new(Memo { by_allocation: HashMap::new(), prune_at: 256, hashed: 0 }))
}

fn hash(bytes: &[u8]) -> u64 {
    let mut h = std::hash::DefaultHasher::new();
    bytes.hash(&mut h);
    h.finish().max(1)
}

/// The id of `bytes`, hashed once per allocation: a blob is an `Arc` cloned
/// through every row and batch that holds it, so the memo is keyed by the
/// allocation and checked against a weak handle that dies with it. Never 0,
/// which a backend reads as "no blob".
pub(crate) fn of(bytes: &Arc<[u8]>) -> u64 {
    let at = bytes.as_ptr() as usize;
    let mut m = memo().lock().unwrap();
    if let Some((weak, id)) = m.by_allocation.get(&at) {
        if weak.upgrade().is_some_and(|live| Arc::ptr_eq(&live, bytes)) {
            return *id;
        }
    }
    let id = hash(bytes);
    m.hashed += 1;
    m.by_allocation.insert(at, (Arc::downgrade(bytes), id));
    if m.by_allocation.len() >= m.prune_at {
        m.by_allocation.retain(|_, (weak, _)| weak.strong_count() > 0);
        m.prune_at = (m.by_allocation.len() * 2).max(256);
    }
    id
}

#[cfg(test)]
fn hashed() -> u64 {
    memo().lock().unwrap().hashed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_bytes_share_an_id_and_one_allocation_hashes_once() {
        let a: Arc<[u8]> = Arc::from(&b"\xff\xd8 album art"[..]);
        let b: Arc<[u8]> = Arc::from(&b"\xff\xd8 album art"[..]);
        let c: Arc<[u8]> = Arc::from(&b"\xff\xd8 other art"[..]);
        assert_eq!(of(&a), of(&b), "equal bytes in two allocations");
        assert_ne!(of(&a), of(&c), "different bytes");
        assert_ne!(of(&Arc::from(&b""[..])), 0, "0 is the dead handle's answer");
        let before = hashed();
        for _ in 0..10 {
            of(&a.clone());
        }
        assert_eq!(hashed(), before, "a clone of a hashed allocation is hashed again");
    }

    #[test]
    fn a_freed_allocation_reused_for_new_bytes_is_hashed_again() {
        let first: Arc<[u8]> = Arc::from(vec![7u8; 4096]);
        of(&first);
        drop(first);
        let second: Arc<[u8]> = Arc::from(vec![9u8; 4096]);
        assert_eq!(of(&second), hash(&second), "the memo answered a dead allocation's id");
    }
}

//! N12's helper (docs/network-images-plan.md): a row's image fetched when
//! the core says the row needs it, and written back with N7's conditional
//! write so a row that was removed or now wants other bytes drops the
//! result. The app hands over the fetch; this binding carries no client.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use super::{AppCtx, BlobKind, Collection, Field, ImagePhaseKind, KayaSum, Messages, Poster, StrKind, Tx};
use crate::protocol::{Blob, ImagePhase, Occurrence, Path, TemplateNodeId, Value};

/// The app's fetch: the bytes at a URL, or why not.
pub type Fetch = dyn Fn(&str) -> Result<Vec<u8>, String> + Send + Sync;

type OnError = dyn Fn(&mut Tx<'_>, &Path, &str) + Send + Sync;

/// Rows whose image loads on demand. Each row holds the URL it wants, its
/// bytes and its phase; a row realized `Loading` with no bytes is fetched
/// on a worker, at most [`RowImages::DEFAULT_LIMIT`] at a time, and rows
/// sharing a URL share one fetch and one copy of the bytes.
pub struct RowImages<T: KayaSum + Send + Sync + 'static> {
    shared: Arc<Shared<T>>,
}

struct Shared<T: KayaSum> {
    rows: Collection<T>,
    url: u32,
    art: u32,
    phase: u32,
    fetch: Arc<Fetch>,
    poster: Poster,
    limit: usize,
    on_error: Mutex<Option<Arc<OnError>>>,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    queue: VecDeque<String>,
    /// The rows waiting on each URL queued or in flight.
    waiting: HashMap<String, Vec<Path>>,
    workers: usize,
    cache: Cache,
}

/// The encoded bytes by URL, least recently used out past a byte budget.
#[derive(Default)]
struct Cache {
    entries: HashMap<String, (Arc<[u8]>, u64)>,
    bytes: usize,
    tick: u64,
}

impl Cache {
    const BUDGET: usize = 32 << 20;

    fn get(&mut self, url: &str) -> Option<Arc<[u8]>> {
        self.tick += 1;
        let tick = self.tick;
        self.entries.get_mut(url).map(|(bytes, used)| {
            *used = tick;
            bytes.clone()
        })
    }

    fn put(&mut self, url: String, bytes: Arc<[u8]>) {
        self.tick += 1;
        self.bytes += bytes.len();
        if let Some((old, _)) = self.entries.insert(url, (bytes, self.tick)) {
            self.bytes -= old.len();
        }
        while self.bytes > Self::BUDGET && self.entries.len() > 1 {
            let Some(oldest) = self.entries.iter().min_by_key(|(_, (_, used))| *used).map(|(k, _)| k.clone()) else {
                break;
            };
            if let Some((gone, _)) = self.entries.remove(&oldest) {
                self.bytes -= gone.len();
            }
        }
    }
}

impl<T: KayaSum + Send + Sync + 'static> RowImages<T> {
    pub const DEFAULT_LIMIT: usize = 6;

    /// `url`, `art` and `phase` are the row's fields; `rows` is the root
    /// handle of the collection the template image's For stamps.
    pub fn new(
        ctx: &AppCtx,
        rows: &Collection<T>,
        url: Field<StrKind>,
        art: Field<BlobKind>,
        phase: Field<ImagePhaseKind>,
        fetch: impl Fn(&str) -> Result<Vec<u8>, String> + Send + Sync + 'static,
    ) -> Self {
        RowImages {
            shared: Arc::new(Shared {
                rows: rows.clone(),
                url: url.index,
                art: art.index,
                phase: phase.index,
                fetch: Arc::new(fetch),
                poster: ctx.poster(),
                limit: Self::DEFAULT_LIMIT,
                on_error: Mutex::new(None),
                state: Mutex::new(State::default()),
            }),
        }
    }

    /// Run on the app thread inside the transaction that writes `failed`.
    pub fn on_error(&self, f: impl Fn(&mut Tx<'_>, &Path, &str) + Send + Sync + 'static) {
        *self.shared.on_error.lock().unwrap() = Some(Arc::new(f));
    }

    /// Fetch for the stamped copies of template image `node`.
    pub fn attach<M>(&self, msgs: &Messages<M>, node: TemplateNodeId) {
        let shared = self.shared.clone();
        msgs.image_feeds.borrow_mut().entry(node.0).or_default().push(Box::new(move |ctx, occ| match occ {
            Occurrence::ImageNeeded { path, .. } => Shared::needed(&shared, ctx, path),
            Occurrence::ImageReleased { path, .. } => shared.released(path),
            _ => {}
        }));
    }
}

impl<T: KayaSum + Send + Sync + 'static> Shared<T> {
    fn instance(&self, path: &Path) -> Option<(Collection<T>, Value)> {
        let (key, prefix) = path.split_last()?;
        let mut rows = self.rows.clone();
        rows.path = prefix.to_vec();
        Some((rows, key.clone()))
    }

    fn needed(shared: &Arc<Self>, ctx: &AppCtx, path: &Path) {
        let Some((rows, key)) = shared.instance(path) else { return };
        let url = ctx
            .model
            .borrow()
            .get(&rows.id)
            .and_then(|instances| instances.iter().find(|i| i.path == rows.path))
            .and_then(|i| i.entries.iter().find(|(k, _, _)| *k == key))
            .and_then(|(_, _, record)| match record.get(shared.url as usize) {
                Some(Value::Str(url)) if !url.is_empty() => Some(url.clone()),
                _ => None,
            });
        let Some(url) = url else { return };
        let mut state = shared.state.lock().unwrap();
        if let Some(bytes) = state.cache.get(&url) {
            drop(state);
            shared.write(vec![path.clone()], url, Ok(bytes));
            return;
        }
        let waiting = state.waiting.entry(url.clone()).or_default();
        waiting.push(path.clone());
        if waiting.len() > 1 {
            return;
        }
        state.queue.push_back(url);
        if state.workers < shared.limit {
            state.workers += 1;
            let worker = shared.clone();
            std::thread::Builder::new()
                .name("kaya-row-images".into())
                .spawn(move || worker.work())
                .expect("kaya: could not start a row-image worker");
        }
    }

    /// A released row stops waiting; a URL nobody waits on any longer is
    /// not fetched. A fetch already running finishes and its write, if any
    /// row still wants it, is guarded like every other.
    fn released(&self, path: &Path) {
        let mut state = self.state.lock().unwrap();
        let mut emptied = Vec::new();
        for (url, rows) in state.waiting.iter_mut() {
            rows.retain(|p| p != path);
            if rows.is_empty() {
                emptied.push(url.clone());
            }
        }
        for url in emptied {
            if let Some(at) = state.queue.iter().position(|u| *u == url) {
                state.queue.remove(at);
                state.waiting.remove(&url);
            }
        }
    }

    fn work(self: Arc<Self>) {
        loop {
            let url = {
                let mut state = self.state.lock().unwrap();
                match state.queue.pop_front() {
                    Some(url) => url,
                    None => {
                        state.workers -= 1;
                        return;
                    }
                }
            };
            let got = (self.fetch)(&url).map(|bytes| Arc::<[u8]>::from(bytes));
            let rows = {
                let mut state = self.state.lock().unwrap();
                if let Ok(bytes) = &got {
                    state.cache.put(url.clone(), bytes.clone());
                }
                state.waiting.remove(&url).unwrap_or_default()
            };
            if !rows.is_empty() {
                self.write(rows, url, got);
            }
        }
    }

    fn write(&self, rows: Vec<Path>, url: String, got: Result<Arc<[u8]>, String>) {
        let writes: Vec<(Collection<T>, Value)> = rows.iter().filter_map(|p| self.instance(p)).collect();
        let (art, phase, url_field) = (self.art, self.phase, self.url);
        let on_error = self.on_error.lock().unwrap().clone();
        self.poster.post(move |tx| {
            for ((instance, key), path) in writes.into_iter().zip(rows.iter()) {
                let changes = match &got {
                    Ok(bytes) => vec![
                        (art, Value::Blob(Blob(bytes.clone()))),
                        (phase, Value::from(ImagePhase::Shown)),
                    ],
                    Err(_) => vec![(phase, Value::from(ImagePhase::Failed))],
                };
                tx.patch_if_raw(&instance, key, 0, url_field, Value::Str(url.clone()), changes);
                if let (Err(why), Some(f)) = (&got, &on_error) {
                    f(tx, path, why);
                }
            }
        });
    }
}

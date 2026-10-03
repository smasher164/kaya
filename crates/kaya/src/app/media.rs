//! The Rust binding's media surface (docs/media-plan.md): a player object
//! the app holds, the video view that shows one, the one session, the
//! mirror of each player's readings and the capability query.

use super::{Messages, Tx, Widget};
use crate::protocol::{
    Fit, MediaFailure, Occurrence, Path, PlaybackState, PlayerCommand, PlayerId, PlayerProp, PlayerState,
    PlayerTracks, SessionAction, SessionActionKind, SessionSpec, TemplateNodeId, TrackKind, TxOp, Value,
    WidgetId,
};

/// Where a player reads its media from: an asset under the app's asset
/// root, an http(s) URL, or a file the user picked. Never bytes
/// (docs/media-plan.md §2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaSource(Named);

#[derive(Debug, Clone, PartialEq, Eq)]
enum Named {
    Text(String),
    Picked(crate::protocol::PickedId),
}

impl MediaSource {
    pub fn asset(name: impl Into<String>) -> Self {
        MediaSource(Named::Text(name.into()))
    }

    pub fn url(url: impl Into<String>) -> Self {
        MediaSource(Named::Text(url.into()))
    }

    /// The picked file itself, which the platform's player opens however
    /// the platform names it: a path, a `content://` URI, an iOS URL.
    pub fn picked(file: &crate::protocol::PickedFile) -> Self {
        MediaSource(Named::Picked(file.handle))
    }

    fn value(&self) -> Value {
        match &self.0 {
            Named::Text(s) => Value::Str(s.clone()),
            Named::Picked(handle) => Value::I64(handle.0 as i64),
        }
    }
}

/// A player's readings, as the core last published them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlayerReading {
    pub state: PlayerState,
    pub failure: Option<MediaFailure>,
    pub position_ms: u64,
    pub duration_ms: u64,
    /// The picture's size; 0x0 for audio.
    pub width: u32,
    pub height: u32,
}

impl Default for PlayerReading {
    fn default() -> Self {
        PlayerReading {
            state: PlayerState::Idle,
            failure: None,
            position_ms: 0,
            duration_ms: 0,
            width: 0,
            height: 0,
        }
    }
}

/// Whether this platform plays `mime` with `codecs` (an RFC 6381 list, ""
/// for none): true exactly when loading such media would not fail as
/// `unsupported_codec` or `unsupported_container` (docs/media-plan.md §8
/// ruling 1).
pub fn can_play(mime: &str, codecs: &str) -> bool {
    unsafe { crate::capi::kaya_can_play(mime.as_ptr(), mime.len(), codecs.as_ptr(), codecs.len()) != 0 }
}

impl super::AppCtx {
    pub(super) fn alloc_player(&self) -> PlayerId {
        let id = self.next_player.get();
        self.next_player.set(id + 1);
        PlayerId(id)
    }

    /// A player's readings: its state, where it is, how long it is and its
    /// picture's size, as of the last occurrence this loop took.
    pub fn player(&self, player: PlayerId) -> PlayerReading {
        self.players.borrow().get(&player.0).copied().unwrap_or_default()
    }

    /// A player's tracks (docs/media-plan.md §3): language tags in the
    /// platform's order, a sidecar caption track last, and the selections.
    pub fn tracks(&self, player: PlayerId) -> PlayerTracks {
        self.player_tracks.borrow().get(&player.0).map(|(t, _)| t.clone()).unwrap_or_default()
    }

    /// The caption cue current on the player's clock, "" for none.
    pub fn cue(&self, player: PlayerId) -> String {
        self.player_tracks.borrow().get(&player.0).map(|(_, c)| c.clone()).unwrap_or_default()
    }

    pub(super) fn absorb_player(&self, occ: &Occurrence) {
        match occ {
            Occurrence::PlayerTracks { player, tracks } => {
                self.player_tracks.borrow_mut().entry(player.0).or_default().0 = tracks.clone();
                return;
            }
            Occurrence::CaptionCue { player, text } => {
                self.player_tracks.borrow_mut().entry(player.0).or_default().1 = text.clone();
                return;
            }
            _ => {}
        }
        let mut players = self.players.borrow_mut();
        match occ {
            Occurrence::PlayerChanged { player, state, failure, duration_ms, width, height, .. } => {
                let r = players.entry(player.0).or_default();
                r.state = *state;
                r.failure = *failure;
                r.duration_ms = *duration_ms;
                r.width = *width;
                r.height = *height;
                if *state == PlayerState::Loading || *state == PlayerState::Idle {
                    r.position_ms = 0;
                }
            }
            Occurrence::PlayerPosition { player, position_ms }
            | Occurrence::SeekCompleted { player, position_ms } => {
                players.entry(player.0).or_default().position_ms = *position_ms;
            }
            _ => {}
        }
    }
}

impl<'a> Tx<'a> {
    /// A media player (docs/media-plan.md §2): an object with no place in
    /// the layout. Show it with [`Tx::video`]; shown by none it is audio.
    pub fn player(&mut self) -> PlayerRef<'_, 'a> {
        let player = self.ctx.alloc_player();
        self.ops.push(TxOp::CreatePlayer { player });
        PlayerRef { tx: self, player }
    }

    fn player_prop(&mut self, player: PlayerId, prop: PlayerProp, value: Value) {
        self.ops.push(TxOp::SetPlayerProp { player, prop, value });
    }

    /// Load `source`, replacing what the player held; it reads `loading`
    /// until the platform answers.
    pub fn player_source(&mut self, player: PlayerId, source: &MediaSource) {
        self.player_prop(player, PlayerProp::Source, source.value());
    }

    /// Unload, back to `idle`.
    pub fn clear_player(&mut self, player: PlayerId) {
        self.player_prop(player, PlayerProp::Source, Value::Str(String::new()));
    }

    pub fn player_speed(&mut self, player: PlayerId, rate: f64) {
        self.player_prop(player, PlayerProp::Speed, Value::F64(rate));
    }

    /// 0..=1, relative to the system volume.
    pub fn player_volume(&mut self, player: PlayerId, volume: f64) {
        self.player_prop(player, PlayerProp::Volume, Value::F64(volume));
    }

    pub fn player_muted(&mut self, player: PlayerId, on: bool) {
        self.player_prop(player, PlayerProp::Muted, Value::Bool(on));
    }

    pub fn player_loop(&mut self, player: PlayerId, on: bool) {
        self.player_prop(player, PlayerProp::Loop, Value::Bool(on));
    }

    /// Play; from the start when the player had ended.
    pub fn play(&mut self, player: PlayerId) {
        self.ops.push(TxOp::PlayerCommand { player, command: PlayerCommand::Play });
    }

    pub fn pause(&mut self, player: PlayerId) {
        self.ops.push(TxOp::PlayerCommand { player, command: PlayerCommand::Pause });
    }

    /// To `ms` from the start; `on_seek_completed` hears where it landed.
    pub fn seek(&mut self, player: PlayerId, ms: u64) {
        self.ops.push(TxOp::PlayerCommand { player, command: PlayerCommand::Seek(ms) });
    }

    pub fn release_player(&mut self, player: PlayerId) {
        self.ops.push(TxOp::ReleasePlayer { player });
    }

    /// Show another player in a video view, or none. A player is shown by
    /// one video view at a time (docs/media-plan.md §7b).
    pub fn show_player(&mut self, video: WidgetId, player: Option<PlayerId>) {
        self.set(video, crate::protocol::Prop::Player, Value::I64(player.map_or(0, |p| p.0 as i64)));
    }

    /// Select audio track `index` (0-based in [`super::AppCtx::tracks`]).
    pub fn select_audio(&mut self, player: PlayerId, index: usize) {
        self.ops.push(TxOp::SelectTrack { player, kind: TrackKind::Audio, index: index as u32 + 1 });
    }

    /// Select a caption track (0-based in [`super::AppCtx::tracks`]), or
    /// none; a sidecar file's track is selected the same way.
    pub fn select_captions(&mut self, player: PlayerId, index: Option<usize>) {
        let index = index.map_or(0, |i| i as u32 + 1);
        self.ops.push(TxOp::SelectTrack { player, kind: TrackKind::Caption, index });
    }

    /// A sidecar WebVTT file for the player (an asset name, a picked file,
    /// or an http(s) URL the platform fetches), `language` its BCP 47 tag:
    /// kaya parses it and draws its cues, listed as the last caption track
    /// (docs/media-plan.md §3).
    pub fn player_captions(&mut self, player: PlayerId, source: &MediaSource, language: &str) {
        self.player_prop(player, PlayerProp::CaptionsLanguage, Value::Str(language.to_owned()));
        self.player_prop(player, PlayerProp::Captions, source.value());
    }

    /// No sidecar captions.
    pub fn clear_captions(&mut self, player: PlayerId) {
        self.player_prop(player, PlayerProp::Captions, Value::Str(String::new()));
    }

    /// Declare the app's one media session, replacing the last
    /// (docs/media-plan.md §5). `.declare()` sends it.
    pub fn session(&mut self) -> SessionRef<'_, 'a> {
        SessionRef { tx: self, spec: SessionSpec::default() }
    }
}

impl<R> Widget<'_, '_, R> {
    /// How a video view fits its picture (docs/media-plan.md §3).
    pub fn fit(self, fit: Fit) -> Self {
        let raw = match fit {
            Fit::Contain => 0i64,
            Fit::Cover => 1,
            Fit::Fill => 2,
        };
        self.tx.set(self.id, crate::protocol::Prop::Fit, raw);
        self
    }
}

#[must_use = "a player's settings apply as they are chained; .id() hands the player back"]
pub struct PlayerRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    player: PlayerId,
}

impl PlayerRef<'_, '_> {
    pub fn source(self, source: &MediaSource) -> Self {
        self.tx.player_source(self.player, source);
        self
    }

    pub fn speed(self, rate: f64) -> Self {
        self.tx.player_speed(self.player, rate);
        self
    }

    pub fn volume(self, volume: f64) -> Self {
        self.tx.player_volume(self.player, volume);
        self
    }

    pub fn muted(self, on: bool) -> Self {
        self.tx.player_muted(self.player, on);
        self
    }

    pub fn looping(self, on: bool) -> Self {
        self.tx.player_loop(self.player, on);
        self
    }

    pub fn captions(self, source: &MediaSource, language: &str) -> Self {
        self.tx.player_captions(self.player, source, language);
        self
    }

    pub fn id(self) -> PlayerId {
        self.player
    }
}

#[must_use = "a session is declared by .declare()"]
pub struct SessionRef<'t, 'a> {
    tx: &'t mut Tx<'a>,
    spec: SessionSpec,
}

impl SessionRef<'_, '_> {
    /// The player the system's controls speak to; without one, the app's
    /// own handlers are all there is.
    pub fn player(mut self, player: PlayerId) -> Self {
        self.spec.player = Some(player);
        self
    }

    pub fn title(mut self, title: impl Into<String>) -> Self {
        self.spec.title = title.into();
        self
    }

    pub fn artist(mut self, artist: impl Into<String>) -> Self {
        self.spec.artist = artist.into();
        self
    }

    pub fn album(mut self, album: impl Into<String>) -> Self {
        self.spec.album = album.into();
        self
    }

    /// An asset name.
    pub fn artwork(mut self, asset: impl Into<String>) -> Self {
        self.spec.artwork = asset.into();
        self
    }

    /// The actions the app answers itself through [`Messages::on_session`];
    /// play, pause and seek_to it leaves out apply to the attached player.
    pub fn handles(mut self, actions: &[SessionActionKind]) -> Self {
        for action in actions {
            self.spec.actions |= action.bit();
        }
        self
    }

    /// What the system shows while no player is attached.
    pub fn playback_state(mut self, state: PlaybackState) -> Self {
        self.spec.playback_state = state;
        self
    }

    pub fn declare(self) {
        self.tx.ops.push(TxOp::SetSession(self.spec));
    }
}

impl<M> Messages<M> {
    fn on_player_occ(&self, player: PlayerId, f: impl Fn(&Occurrence) -> Option<M> + 'static) {
        self.players.borrow_mut().entry(player.0).or_default().push(Box::new(f));
    }

    /// Every state the player moves to, `ended` and `failed` included.
    pub fn on_player_state(&self, player: PlayerId, f: impl Fn(PlayerState) -> M + 'static) {
        self.on_player_occ(player, move |occ| match occ {
            Occurrence::PlayerChanged { state, .. } => Some(f(*state)),
            _ => None,
        });
    }

    /// The player reached its end (never, while it loops).
    pub fn on_ended(&self, player: PlayerId, f: impl Fn() -> M + 'static) {
        self.on_player_occ(player, move |occ| match occ {
            Occurrence::PlayerChanged { state: PlayerState::Ended, .. } => Some(f()),
            _ => None,
        });
    }

    /// The player cannot play: the closed reason, and the platform's
    /// sentence, which no two platforms word alike.
    pub fn on_failed(&self, player: PlayerId, f: impl Fn(MediaFailure, &str) -> M + 'static) {
        self.on_player_occ(player, move |occ| match occ {
            Occurrence::PlayerChanged { state: PlayerState::Failed, failure: Some(why), detail, .. } => {
                Some(f(*why, detail))
            }
            _ => None,
        });
    }

    /// Where a seek the app asked for landed, in ms.
    pub fn on_seek_completed(&self, player: PlayerId, f: impl Fn(u64) -> M + 'static) {
        self.on_player_occ(player, move |occ| match occ {
            Occurrence::SeekCompleted { position_ms, .. } => Some(f(*position_ms)),
            _ => None,
        });
    }

    /// The playhead, every KAYA_MEDIA_POSITION_TICK_MS while playing.
    pub fn on_position(&self, player: PlayerId, f: impl Fn(u64) -> M + 'static) {
        self.on_player_occ(player, move |occ| match occ {
            Occurrence::PlayerPosition { position_ms, .. } => Some(f(*position_ms)),
            _ => None,
        });
    }

    /// The player's track listing or a selection moved.
    pub fn on_tracks(&self, player: PlayerId, f: impl Fn(&PlayerTracks) -> M + 'static) {
        self.on_player_occ(player, move |occ| match occ {
            Occurrence::PlayerTracks { tracks, .. } => Some(f(tracks)),
            _ => None,
        });
    }

    /// The current caption cue changed ("" between cues), whoever draws it.
    pub fn on_cue(&self, player: PlayerId, f: impl Fn(&str) -> M + 'static) {
        self.on_player_occ(player, move |occ| match occ {
            Occurrence::CaptionCue { text, .. } => Some(f(text)),
            _ => None,
        });
    }

    /// How much of the video view shows, 0 to 1, as it enters, leaves,
    /// moves by a tenth and shows whole (docs/media-plan.md §7b).
    pub fn on_visibility(&self, video: WidgetId, f: impl Fn(f64) -> M + 'static) {
        self.widgets.borrow_mut().entry(video.0).or_default().push(Box::new(move |occ| match occ {
            Occurrence::VideoVisibility { shown, .. } => Some(f(*shown)),
            _ => None,
        }));
    }

    /// A stamped video view's visibility, the copy's keys first.
    pub fn on_visibility_node(&self, n: TemplateNodeId, f: impl Fn(Path, f64) -> M + 'static) {
        self.nodes.borrow_mut().entry(n.0).or_default().push(Box::new(move |occ| match occ {
            Occurrence::InstanceVideoVisibility { path, shown, .. } => Some(f(path.clone(), *shown)),
            _ => None,
        }));
    }

    /// The actions the declared session handles, from the system's media
    /// controls (docs/media-plan.md §5).
    pub fn on_session(&self, f: impl Fn(SessionAction) -> M + 'static) {
        *self.session.borrow_mut() = Some(Box::new(f));
    }

    pub(super) fn dispatch_media(&self, occ: &Occurrence) -> Option<M> {
        match occ {
            Occurrence::PlayerChanged { player, .. }
            | Occurrence::PlayerPosition { player, .. }
            | Occurrence::SeekCompleted { player, .. }
            | Occurrence::PlayerTracks { player, .. }
            | Occurrence::CaptionCue { player, .. } => self
                .players
                .borrow()
                .get(&player.0)
                .and_then(|fs| fs.iter().rev().find_map(|f| f(occ))),
            Occurrence::SessionAction { action } => self.session.borrow().as_ref().map(|f| f(*action)),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------
// The reader and the core-held images (docs/media-plan.md §8 rulings 3, 4)
// ---------------------------------------------------------------------

use crate::protocol::{FrameAccuracy, ImageId, Peaks, ReadId, ReadOutcome, ReaderId};

/// One requested time answered: which of the times it is, the time asked,
/// the time of the picture the platform returned, and the core-held image
/// the canvas's [`super::Draw::image`] draws. The image is the app's until
/// it releases it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    pub index: usize,
    pub requested_ms: u64,
    pub actual_ms: u64,
    pub image: ImageId,
    pub width: u32,
    pub height: u32,
}

/// Why an awaited read gave no answer: the reader was closed under it, or
/// the platform failed it with the player's closed reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadError {
    Cancelled,
    Failed(MediaFailure, String),
}

impl super::AppCtx {
    pub(super) fn alloc_reader(&self) -> ReaderId {
        let id = self.next_reader.get();
        self.next_reader.set(id + 1);
        ReaderId(id)
    }

    pub(super) fn alloc_read(&self, reader: ReaderId) -> ReadId {
        let id = self.next_read.get();
        self.next_read.set(id + 1);
        self.reads_in_flight.borrow_mut().insert(reader.0, id);
        ReadId(id)
    }

    pub(super) fn alloc_images(&self, n: usize) -> ImageId {
        let first = self.next_image.get();
        self.next_image.set(first + n as u64);
        ImageId(first)
    }

    /// The app gave up on `read`: answers of it still in the channel are
    /// not heard, and the images they carry are released by the next commit.
    fn abandon(&self, read: u64) {
        self.abandoned_reads.borrow_mut().insert(read);
        self.reads_in_flight.borrow_mut().retain(|_, r| *r != read);
    }

    /// An image's premultiplied RGBA8 bytes and size, for an app that keeps
    /// its pictures; None for an image holding none.
    pub fn image_pixels(&self, image: ImageId) -> Option<(u32, u32, Vec<u8>)> {
        crate::reader::pulled_pixels(image)
    }

    /// The occurrence half of the reader: an abandoned read's answers
    /// dropped, an awaited read's taken by its future. True when consumed.
    pub(super) fn absorb_read(&self, occ: &Occurrence) -> bool {
        let read = match occ {
            Occurrence::ReaderFrame { read, .. }
            | Occurrence::ReaderProgress { read, .. }
            | Occurrence::ReaderPeaks { read, .. }
            | Occurrence::ReaderDone { read, .. } => read.0,
            _ => return false,
        };
        if let Occurrence::ReaderDone { reader, .. } = occ {
            let mut flight = self.reads_in_flight.borrow_mut();
            if flight.get(&reader.0) == Some(&read) {
                flight.remove(&reader.0);
            }
        }
        if self.abandoned_reads.borrow().contains(&read) {
            match occ {
                Occurrence::ReaderFrame { image, .. } => {
                    self.pending_ops.borrow_mut().push(TxOp::ReleaseImage { image: *image })
                }
                Occurrence::ReaderDone { .. } => {
                    self.abandoned_reads.borrow_mut().remove(&read);
                    return self.read_replies.borrow_mut().remove(&read).is_some();
                }
                _ => {}
            }
            return true;
        }
        let Some(cell) = self.read_replies.borrow().get(&read).cloned() else { return false };
        let mut reply = cell.lock().unwrap();
        match occ {
            Occurrence::ReaderFrame { index, image, width, height, requested_ms, actual_ms, .. } => {
                reply.frames.push(Frame {
                    index: *index as usize,
                    requested_ms: *requested_ms,
                    actual_ms: *actual_ms,
                    image: *image,
                    width: *width,
                    height: *height,
                });
            }
            Occurrence::ReaderPeaks { peaks, .. } => reply.peaks = Some(peaks.clone()),
            Occurrence::ReaderDone { outcome, .. } => {
                if !matches!(outcome, ReadOutcome::Completed) {
                    let mut pending = self.pending_ops.borrow_mut();
                    for f in reply.frames.drain(..) {
                        pending.push(TxOp::ReleaseImage { image: f.image });
                    }
                }
                reply.done = Some(outcome.clone());
                if let Some(waker) = reply.waker.take() {
                    waker.wake();
                }
                drop(reply);
                self.read_replies.borrow_mut().remove(&read);
            }
            _ => {}
        }
        true
    }

    fn await_read(&self, reader: ReaderId, op: impl FnOnce(&mut Tx<'_>) -> ReadId) -> ReadFuture<'_> {
        self.check_async_request();
        let reply: ReadReplyCell = std::sync::Arc::new(std::sync::Mutex::new(ReadReply::default()));
        let read = self.apply(|tx| op(tx));
        self.read_replies.borrow_mut().insert(read.0, reply.clone());
        ReadFuture { ctx: self, reader, read, reply }
    }

    /// The frames at `times_ms` as one awaited read (the binding's async
    /// tier, docs/async-dialogs-plan.md §2.4): dropping the future cancels
    /// the read and releases whatever images it had carried.
    pub fn frames(
        &self,
        reader: ReaderId,
        times_ms: &[u64],
        max_size: (u32, u32),
        accuracy: FrameAccuracy,
    ) -> impl std::future::Future<Output = Result<Vec<Frame>, ReadError>> + '_ {
        let future = self.await_read(reader, |tx| tx.read_frames(reader, times_ms, max_size, accuracy));
        async move {
            let mut answer = future.await?;
            answer.frames.sort_by_key(|f| f.index);
            Ok(answer.frames)
        }
    }

    /// The reader's peaks as one awaited read.
    pub fn peaks(
        &self,
        reader: ReaderId,
        samples_per_pair: u32,
    ) -> impl std::future::Future<Output = Result<Peaks, ReadError>> + '_ {
        let future = self.await_read(reader, |tx| tx.read_peaks(reader, samples_per_pair));
        async move { Ok(future.await?.peaks.unwrap_or_default()) }
    }
}

#[derive(Default)]
pub(super) struct ReadReply {
    frames: Vec<Frame>,
    peaks: Option<Peaks>,
    done: Option<ReadOutcome>,
    waker: Option<std::task::Waker>,
}

pub(super) type ReadReplyCell = std::sync::Arc<std::sync::Mutex<ReadReply>>;

struct ReadFuture<'a> {
    ctx: &'a super::AppCtx,
    reader: ReaderId,
    read: ReadId,
    reply: ReadReplyCell,
}

impl std::future::Future for ReadFuture<'_> {
    type Output = Result<ReadReply, ReadError>;

    fn poll(self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<Self::Output> {
        let mut reply = self.reply.lock().unwrap();
        match reply.done.take() {
            Some(ReadOutcome::Completed) => std::task::Poll::Ready(Ok(std::mem::take(&mut *reply))),
            Some(ReadOutcome::Cancelled) => std::task::Poll::Ready(Err(ReadError::Cancelled)),
            Some(ReadOutcome::Failed(why, detail)) => std::task::Poll::Ready(Err(ReadError::Failed(why, detail))),
            None => {
                reply.waker = Some(cx.waker().clone());
                std::task::Poll::Pending
            }
        }
    }
}

impl Drop for ReadFuture<'_> {
    /// A future dropped before its answer: the read is cancelled, its
    /// answers are not heard, and the images it already carried go back.
    fn drop(&mut self) {
        let mut reply = self.reply.lock().unwrap();
        if reply.done.is_some() || self.ctx.read_replies.borrow().get(&self.read.0).is_none() {
            return;
        }
        self.ctx.read_replies.borrow_mut().remove(&self.read.0);
        let mut ops: Vec<TxOp> =
            reply.frames.drain(..).map(|f| TxOp::ReleaseImage { image: f.image }).collect();
        drop(reply);
        self.ctx.abandon(self.read.0);
        ops.push(TxOp::CancelRead { reader: self.reader, read: self.read });
        self.ctx.pending_ops.borrow_mut().extend(ops);
        if self.ctx.open_transactions.get() == 0 && !self.ctx.shutdown.get() {
            self.ctx.apply(|_| {});
        }
    }
}

impl<'a> Tx<'a> {
    /// A media reader on `source` (docs/media-plan.md §8 ruling 4): frames
    /// and peaks without a player.
    pub fn reader(&mut self, source: &MediaSource) -> ReaderId {
        let reader = self.ctx.alloc_reader();
        self.ops.push(TxOp::OpenReader { reader, source: source.value() });
        reader
    }

    /// One picture per time in `times_ms`, each heard through
    /// [`Messages::on_frame`] and the read's end through
    /// [`Messages::on_read_done`]. `max_size` bounds the picture, aspect
    /// kept, 0 for no bound on that axis. One read in flight per reader.
    pub fn read_frames(
        &mut self,
        reader: ReaderId,
        times_ms: &[u64],
        max_size: (u32, u32),
        accuracy: FrameAccuracy,
    ) -> ReadId {
        let read = self.ctx.alloc_read(reader);
        let first_image = self.ctx.alloc_images(times_ms.len());
        self.ops.push(TxOp::ReadFrames {
            reader,
            read,
            first_image,
            accuracy,
            max_size,
            times_ms: times_ms.to_vec(),
        });
        read
    }

    /// The first audio track's peaks, a min/max pair per channel per
    /// `samples_per_pair` frames, heard through [`Messages::on_peaks`].
    pub fn read_peaks(&mut self, reader: ReaderId, samples_per_pair: u32) -> ReadId {
        let read = self.ctx.alloc_read(reader);
        self.ops.push(TxOp::ReadPeaks { reader, read, samples_per_pair });
        read
    }

    /// Stop a read: it ends cancelled, and nothing else of it is heard.
    pub fn cancel_read(&mut self, reader: ReaderId, read: ReadId) {
        self.ctx.abandon(read.0);
        self.ops.push(TxOp::CancelRead { reader, read });
    }

    /// Forget a reader, cancelling its read in flight. The images it
    /// answered with stay the app's.
    pub fn close_reader(&mut self, reader: ReaderId) {
        let in_flight = self.ctx.reads_in_flight.borrow().get(&reader.0).copied();
        if let Some(read) = in_flight {
            self.ctx.abandon(read);
        }
        self.ops.push(TxOp::CloseReader { reader });
    }

    /// An image decoded by kaya from an asset or a picked file, heard
    /// through [`Messages::on_image_loaded`]; a drawing may name it in the
    /// same transaction.
    pub fn load_image(&mut self, source: &MediaSource) -> ImageId {
        let image = self.ctx.alloc_images(1);
        self.ops.push(TxOp::LoadImage { image, source: source.value() });
        image
    }

    pub fn release_image(&mut self, image: ImageId) {
        self.ops.push(TxOp::ReleaseImage { image });
    }
}

impl<M> Messages<M> {
    fn on_read_occ(&self, read: ReadId, f: impl Fn(&Occurrence) -> Option<M> + 'static) {
        self.reads.borrow_mut().entry(read.0).or_default().push(Box::new(f));
    }

    /// Each time of a read_frames as it is answered, in the platform's order.
    pub fn on_frame(&self, read: ReadId, f: impl Fn(Frame) -> M + 'static) {
        self.on_read_occ(read, move |occ| match occ {
            Occurrence::ReaderFrame { index, image, width, height, requested_ms, actual_ms, .. } => Some(f(Frame {
                index: *index as usize,
                requested_ms: *requested_ms,
                actual_ms: *actual_ms,
                image: *image,
                width: *width,
                height: *height,
            })),
            _ => None,
        });
    }

    /// A peaks read's progress: milliseconds decoded of the total.
    pub fn on_read_progress(&self, read: ReadId, f: impl Fn(u64, u64) -> M + 'static) {
        self.on_read_occ(read, move |occ| match occ {
            Occurrence::ReaderProgress { done_ms, total_ms, .. } => Some(f(*done_ms, *total_ms)),
            _ => None,
        });
    }

    /// A peaks read's answer, just before its end.
    pub fn on_peaks(&self, read: ReadId, f: impl Fn(&Peaks) -> M + 'static) {
        self.on_read_occ(read, move |occ| match occ {
            Occurrence::ReaderPeaks { peaks, .. } => Some(f(peaks)),
            _ => None,
        });
    }

    /// The read's end: completed, cancelled or failed. Its registrations
    /// retire with it.
    pub fn on_read_done(&self, read: ReadId, f: impl Fn(ReadOutcome) -> M + 'static) {
        self.on_read_occ(read, move |occ| match occ {
            Occurrence::ReaderDone { outcome, .. } => Some(f(outcome.clone())),
            _ => None,
        });
    }

    /// A load_image's answer: the size, or the reason and the decoder's sentence.
    pub fn on_image_loaded(
        &self,
        image: ImageId,
        f: impl Fn(Result<(u32, u32), (MediaFailure, String)>) -> M + 'static,
    ) {
        self.image_loads.borrow_mut().entry(image.0).or_default().push(Box::new(move |occ| match occ {
            Occurrence::ImageLoaded { width, height, failure: None, .. } => Some(f(Ok((*width, *height)))),
            Occurrence::ImageLoaded { failure: Some(why), .. } => Some(f(Err(why.clone()))),
            _ => None,
        }));
    }

    pub(super) fn dispatch_reader(&self, occ: &Occurrence) -> Option<M> {
        match occ {
            Occurrence::ReaderFrame { read, .. }
            | Occurrence::ReaderProgress { read, .. }
            | Occurrence::ReaderPeaks { read, .. } => {
                self.reads.borrow().get(&read.0).and_then(|fs| fs.iter().rev().find_map(|f| f(occ)))
            }
            Occurrence::ReaderDone { read, .. } => {
                let fs = self.reads.borrow_mut().remove(&read.0)?;
                fs.iter().rev().find_map(|f| f(occ))
            }
            Occurrence::ImageLoaded { image, .. } => {
                let fs = self.image_loads.borrow_mut().remove(&image.0)?;
                fs.iter().rev().find_map(|f| f(occ))
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Inbox, Transaction};
    use std::future::Future;
    use std::sync::mpsc::{self, Receiver, Sender};

    fn context() -> (super::super::AppCtx, Receiver<Transaction>, Sender<Inbox>) {
        let (send, receive) = mpsc::channel();
        let (transactions, batches) = mpsc::channel();
        (super::super::AppCtx::new(receive, transactions, send.clone()), batches, send)
    }

    fn frame(reader: ReaderId, read: ReadId, index: u32, image: u64) -> Occurrence {
        Occurrence::ReaderFrame {
            reader,
            read,
            index,
            image: ImageId(image),
            width: 2,
            height: 1,
            requested_ms: 40 * u64::from(index),
            actual_ms: 40 * u64::from(index),
        }
    }

    fn done(reader: ReaderId, read: ReadId, outcome: ReadOutcome) -> Occurrence {
        Occurrence::ReaderDone { reader, read, outcome }
    }

    fn released(batch: &Transaction) -> Vec<u64> {
        batch.iter().filter_map(|op| if let TxOp::ReleaseImage { image } = op { Some(image.0) } else { None }).collect()
    }

    #[derive(Debug, PartialEq)]
    enum Msg {
        Frame(usize),
        Done(ReadOutcome),
    }

    /// AFTER A CANCEL THE APP HEARS ONLY THE END: answers already in the
    /// channel are dropped, and the images they carried go back with the
    /// next commit, since the app never learned their ids.
    #[test]
    fn a_cancelled_read_is_not_heard_and_its_late_images_go_back() {
        let (ctx, batches, send) = context();
        let msgs = Messages::<Msg>::new();
        let (reader, read) = ctx.apply(|tx| {
            let reader = tx.reader(&MediaSource::asset("media/h264_frames.mp4"));
            (reader, tx.read_frames(reader, &[0, 40], (0, 0), FrameAccuracy::Exact))
        });
        msgs.on_frame(read, |f| Msg::Frame(f.index));
        msgs.on_read_done(read, Msg::Done);
        batches.recv().unwrap();
        ctx.apply(|tx| tx.cancel_read(reader, read));
        batches.recv().unwrap();
        send.send(Inbox::Occ(frame(reader, read, 0, 1))).unwrap();
        send.send(Inbox::Occ(done(reader, read, ReadOutcome::Cancelled))).unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Done(ReadOutcome::Cancelled)));
        ctx.apply(|_| {});
        assert_eq!(released(&batches.recv().unwrap()), vec![1]);
    }

    /// Closing a reader gives up its read in flight the same way.
    #[test]
    fn closing_a_reader_gives_up_its_read() {
        let (ctx, batches, send) = context();
        let msgs = Messages::<Msg>::new();
        let (reader, read) = ctx.apply(|tx| {
            let reader = tx.reader(&MediaSource::asset("media/h264_frames.mp4"));
            (reader, tx.read_frames(reader, &[0], (0, 0), FrameAccuracy::Exact))
        });
        msgs.on_frame(read, |f| Msg::Frame(f.index));
        msgs.on_read_done(read, Msg::Done);
        batches.recv().unwrap();
        ctx.apply(|tx| tx.close_reader(reader));
        assert!(matches!(batches.recv().unwrap().as_slice(), [TxOp::CloseReader { .. }]));
        send.send(Inbox::Occ(frame(reader, read, 0, 1))).unwrap();
        send.send(Inbox::Occ(done(reader, read, ReadOutcome::Cancelled))).unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Done(ReadOutcome::Cancelled)));
        ctx.apply(|_| {});
        assert_eq!(released(&batches.recv().unwrap()), vec![1]);
    }

    #[test]
    fn a_read_in_flight_is_heard_frame_by_frame() {
        let (ctx, _batches, send) = context();
        let msgs = Messages::<Msg>::new();
        let (reader, read) = ctx.apply(|tx| {
            let reader = tx.reader(&MediaSource::asset("media/h264_frames.mp4"));
            (reader, tx.read_frames(reader, &[0, 40], (0, 0), FrameAccuracy::Exact))
        });
        msgs.on_frame(read, |f| Msg::Frame(f.index));
        msgs.on_read_done(read, Msg::Done);
        send.send(Inbox::Occ(frame(reader, read, 1, 2))).unwrap();
        send.send(Inbox::Occ(frame(reader, read, 0, 1))).unwrap();
        send.send(Inbox::Occ(done(reader, read, ReadOutcome::Completed))).unwrap();
        assert_eq!(msgs.next(&ctx), Some(Msg::Frame(1)));
        assert_eq!(msgs.next(&ctx), Some(Msg::Frame(0)));
        assert_eq!(msgs.next(&ctx), Some(Msg::Done(ReadOutcome::Completed)));
        assert!(msgs.reads.borrow().is_empty(), "the read's registrations retired with its end");
    }

    fn poll<F: Future>(fut: std::pin::Pin<&mut F>) -> std::task::Poll<F::Output> {
        fut.poll(&mut std::task::Context::from_waker(std::task::Waker::noop()))
    }

    /// The async tier: the answers in index order, and a future dropped
    /// before its end cancels the read and gives its images back.
    #[test]
    fn an_awaited_read_answers_in_order_and_a_dropped_one_cancels() {
        let (ctx, batches, _send) = context();
        let _tasks = ctx.tasks();
        let reader = ctx.apply(|tx| tx.reader(&MediaSource::asset("media/h264_frames.mp4")));
        batches.recv().unwrap();

        let mut fut = Box::pin(ctx.frames(reader, &[0, 40], (0, 0), FrameAccuracy::Keyframe));
        let read = ReadId(1);
        assert!(matches!(batches.recv().unwrap().as_slice(), [TxOp::ReadFrames { .. }]));
        assert!(poll(fut.as_mut()).is_pending());
        assert!(ctx.absorb_read(&frame(reader, read, 1, 2)));
        assert!(ctx.absorb_read(&frame(reader, read, 0, 1)));
        assert!(ctx.absorb_read(&done(reader, read, ReadOutcome::Completed)));
        match poll(fut.as_mut()) {
            std::task::Poll::Ready(Ok(frames)) => {
                assert_eq!(frames.iter().map(|f| f.index).collect::<Vec<_>>(), vec![0, 1])
            }
            other => panic!("{other:?}"),
        }
        drop(fut);

        let mut fut = Box::pin(ctx.frames(reader, &[0, 40], (0, 0), FrameAccuracy::Keyframe));
        let read = ReadId(2);
        batches.recv().unwrap();
        assert!(poll(fut.as_mut()).is_pending());
        assert!(ctx.absorb_read(&frame(reader, read, 0, 3)));
        drop(fut);
        let batch = batches.recv().unwrap();
        assert!(batch.iter().any(|op| matches!(op, TxOp::CancelRead { read: ReadId(2), .. })));
        assert_eq!(released(&batch), vec![3]);
        assert!(ctx.absorb_read(&frame(reader, read, 1, 4)), "a late answer is not heard");
        assert!(!ctx.absorb_read(&done(reader, read, ReadOutcome::Cancelled)));
        ctx.apply(|_| {});
        assert_eq!(released(&batches.recv().unwrap()), vec![4]);
    }

    /// A read that fails hands back nothing, and what it had carried goes back.
    #[test]
    fn an_awaited_read_that_fails_releases_its_images() {
        let (ctx, batches, _send) = context();
        let _tasks = ctx.tasks();
        let reader = ctx.apply(|tx| tx.reader(&MediaSource::asset("media/h264_frames.mp4")));
        batches.recv().unwrap();
        let mut fut = Box::pin(ctx.frames(reader, &[0, 40], (0, 0), FrameAccuracy::Exact));
        batches.recv().unwrap();
        assert!(poll(fut.as_mut()).is_pending());
        let read = ReadId(1);
        ctx.absorb_read(&frame(reader, read, 0, 1));
        ctx.absorb_read(&done(reader, read, ReadOutcome::Failed(MediaFailure::DecodeError, "x".into())));
        assert!(matches!(
            poll(fut.as_mut()),
            std::task::Poll::Ready(Err(ReadError::Failed(MediaFailure::DecodeError, _)))
        ));
        ctx.apply(|_| {});
        assert_eq!(released(&batches.recv().unwrap()), vec![1]);
    }
}

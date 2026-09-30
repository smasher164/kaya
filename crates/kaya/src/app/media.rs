//! The Rust binding's media surface (docs/media-plan.md): a player object
//! the app holds, the video view that shows one, the one session, the
//! mirror of each player's readings and the capability query.

use super::{Messages, Tx, Widget};
use crate::protocol::{
    Fit, MediaFailure, Occurrence, PlaybackState, PlayerCommand, PlayerId, PlayerProp, PlayerState,
    SessionAction, SessionActionKind, SessionSpec, TxOp, Value, WidgetId,
};

/// Where a player reads its media from: an asset under the app's asset
/// root, an http(s) URL, or a file the user picked. A path, never bytes
/// (docs/media-plan.md §2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaSource(String);

impl MediaSource {
    pub fn asset(name: impl Into<String>) -> Self {
        MediaSource(name.into())
    }

    pub fn url(url: impl Into<String>) -> Self {
        MediaSource(url.into())
    }

    pub fn picked(file: &crate::protocol::PickedFile) -> Self {
        MediaSource(file.local_path.clone())
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

    pub(super) fn absorb_player(&self, occ: &Occurrence) {
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
        self.player_prop(player, PlayerProp::Source, Value::Str(source.0.clone()));
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

    /// Show another player in a video view, or none.
    pub fn show_player(&mut self, video: WidgetId, player: Option<PlayerId>) {
        self.ops.push(TxOp::SetVideoPlayer { widget: video, player });
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

    /// The actions the declared session handles, from the system's media
    /// controls (docs/media-plan.md §5).
    pub fn on_session(&self, f: impl Fn(SessionAction) -> M + 'static) {
        *self.session.borrow_mut() = Some(Box::new(f));
    }

    pub(super) fn dispatch_media(&self, occ: &Occurrence) -> Option<M> {
        match occ {
            Occurrence::PlayerChanged { player, .. }
            | Occurrence::PlayerPosition { player, .. }
            | Occurrence::SeekCompleted { player, .. } => self
                .players
                .borrow()
                .get(&player.0)
                .and_then(|fs| fs.iter().rev().find_map(|f| f(occ))),
            Occurrence::SessionAction { action } => self.session.borrow().as_ref().map(|f| f(*action)),
            _ => None,
        }
    }
}

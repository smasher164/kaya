//! Media: the player's state machine, the failure table, the source's
//! resolution and the session's one-owner rule (docs/media-plan.md §2, §5,
//! §7a). A backend reports what its platform said; this decides what the
//! app hears, so the nine bindings and five platforms read one machine.

use std::collections::HashMap;

use crate::captions::Captions;
use crate::protocol::{
    ApplyOp, MediaFailure, Occurrence, PlaybackState, PlayerCommand, PlayerId, PlayerProp, PlayerState,
    PlayerTracks, SessionAction, SessionSpec, TrackKind, Value, WidgetId,
};

/// How often `player_position` ticks while a player plays.
pub(crate) const POSITION_TICK_MS: u64 = 250;

/// THE BOUND (RULED 2026-10-01, docs/media-plan.md §7c): an open that has
/// not readied, or an app's seek that has not completed, this long after it
/// was asked fails the player `timeout`.
pub(crate) const TIMEOUT_MS: u64 = 30_000;

/// A backend's wake-up timer and the core's clock are two clocks; a wake this
/// close to the bound counts as past it.
pub(crate) const TIMEOUT_SLACK_MS: u64 = 250;

/// What a backend reports about one player, in its platform's own terms.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Report {
    /// The item opened. `undecodable` is the backend's decodability check:
    /// some track the platform cannot decode, even if the rest would play.
    Loaded { duration_ms: u64, size: (u32, u32), undecodable: bool, detail: String },
    /// The platform started (true) or stopped (false) advancing the clock.
    Rate(bool),
    Ended,
    Failed { domain: String, code: i64, underlying: i64, detail: String },
    Position(u64),
    Seeked(u64),
    /// A backend's timer, TIMEOUT_MS after it was handed a source or a
    /// seek: the core reads its own clock and decides.
    Overdue,
    /// The platform's own tracks: language tags in its order, and which of
    /// each list it has selected.
    Tracks { audio: Vec<String>, captions: Vec<String>, audio_selected: Option<usize>, caption_selected: Option<usize> },
    /// The text the platform shows for its own selected caption track now.
    Cue(String),
    /// An http(s) sidecar the backend fetched with the platform's own
    /// networking, `url` echoing the one it was handed.
    CaptionsText { url: String, text: String },
    CaptionsFailed { url: String, domain: String, code: i64, underlying: i64, detail: String },
}

#[derive(Debug, Clone, PartialEq)]
struct Player {
    state: PlayerState,
    failure: Option<MediaFailure>,
    detail: String,
    duration_ms: u64,
    size: (u32, u32),
    looping: bool,
    /// A `playing` report that beat the item's own `loaded` one.
    early_rate: bool,
    /// Seeks the APP asked for and the platform has not yet landed; a seek
    /// the core issued itself (a replay after `ended`) is not the app's.
    seeks: u32,
    /// When the current source was handed over.
    opened_at: Option<std::time::Instant>,
    /// The latest app seek no seek report has followed: when, and where to.
    seek_wait: Option<(std::time::Instant, u64)>,
    /// The platform's own tracks, as it last reported them.
    platform: PlayerTracks,
    /// A sidecar WebVTT file, kaya's to draw, and whether it is selected.
    sidecar: Option<Captions>,
    sidecar_language: String,
    sidecar_selected: bool,
    /// An http(s) sidecar the backend is fetching.
    sidecar_fetch: Option<String>,
    /// What the app last heard: the listing, and the current cue.
    published_tracks: PlayerTracks,
    cue: String,
}

#[cfg(feature = "harness")]
#[derive(Debug, PartialEq)]
pub(crate) struct CaptionSnapshot {
    pub(crate) state: PlayerState,
    pub(crate) duration_ms: u64,
    pub(crate) sidecar: bool,
    pub(crate) selected: bool,
    pub(crate) boundaries: Vec<u64>,
    pub(crate) sidecar_expected: Option<String>,
    pub(crate) published: String,
}

impl Player {
    fn new() -> Self {
        Player {
            state: PlayerState::Idle,
            failure: None,
            detail: String::new(),
            duration_ms: 0,
            size: (0, 0),
            looping: false,
            early_rate: false,
            seeks: 0,
            opened_at: None,
            seek_wait: None,
            platform: PlayerTracks::default(),
            sidecar: None,
            sidecar_language: "und".to_owned(),
            sidecar_selected: false,
            sidecar_fetch: None,
            published_tracks: PlayerTracks::default(),
            cue: String::new(),
        }
    }

    /// Whether the platform holds a decoder open for it: a source handed
    /// over and not failed.
    fn is_open(&self) -> bool {
        !matches!(self.state, PlayerState::Idle | PlayerState::Failed)
    }

    /// The listing the app reads: the platform's tracks, a sidecar's
    /// caption track last.
    fn tracks(&self) -> PlayerTracks {
        let mut t = self.platform.clone();
        if self.sidecar.is_some() {
            t.captions.push(self.sidecar_language.clone());
            if self.sidecar_selected {
                t.caption_selected = Some(t.captions.len() - 1);
            }
        }
        t
    }

    /// The listing, published when it moved.
    fn publish_tracks(&mut self, player: PlayerId, out: &mut Vec<Occurrence>) {
        let now = self.tracks();
        if self.published_tracks != now {
            self.published_tracks = now.clone();
            out.push(Occurrence::PlayerTracks { player, tracks: now });
        }
    }

    /// The current cue, published when its text changed.
    fn publish_cue(&mut self, player: PlayerId, text: String, out: &mut Vec<Occurrence>) {
        if self.cue != text {
            self.cue = text.clone();
            out.push(Occurrence::CaptionCue { player, text });
        }
    }

    fn caption_times(&self, player: PlayerId) -> ApplyOp {
        let times = match (&self.sidecar, self.sidecar_selected) {
            (Some(c), true) => c.boundaries(),
            _ => Vec::new(),
        };
        ApplyOp::CaptionTimes { player, times }
    }
}

/// What the core does with an action the system's media controls sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Route {
    /// The app handles it: publish `session_action`.
    App,
    /// No handler, a player attached: apply this to it.
    Player(PlayerId, PlayerCommand),
    /// Play from the start: the attached player had ended.
    Replay(PlayerId),
    /// Neither: the action was never offered, and a system that sent it
    /// anyway is answered with nothing.
    NotOffered,
}

impl Route {
    /// The code `kaya_session_action` answers the backend with.
    pub(crate) fn code(self) -> u32 {
        match self {
            Route::App => 0,
            Route::Player(_, PlayerCommand::Play) => 1,
            Route::Player(_, PlayerCommand::Pause) => 2,
            Route::Player(_, PlayerCommand::Seek(_)) => 3,
            Route::NotOffered => 4,
            Route::Replay(_) => 5,
        }
    }
}

/// A resolved source: what the backend is handed.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Resolved {
    None,
    Url { url: String },
    Refused(MediaFailure, String),
}

fn bit(action: SessionAction) -> u32 {
    1 << crate::wire::session_action_raw(action).0
}

/// The actions a player attached with no app handler answers by default:
/// the web's recommended defaults, and Windows' own command manager.
fn default_bits() -> u32 {
    bit(SessionAction::Play) | bit(SessionAction::Pause) | bit(SessionAction::SeekTo(0))
}

/// Every player and the one session, held by the scene.
#[derive(Default)]
pub(crate) struct Media {
    players: HashMap<PlayerId, Player>,
    /// Released ids: a row still naming one shows nothing (docs/media-plan.md
    /// §7b), where an id never created is a scene error.
    released: std::collections::HashSet<PlayerId>,
    session: SessionSpec,
    /// Added to the clock, so a unit test can pass the bound.
    skew: std::time::Duration,
}

impl Media {
    fn now(&self) -> std::time::Instant {
        std::time::Instant::now() + self.skew
    }

    pub(crate) fn is_live(&self, player: PlayerId) -> bool {
        self.players.contains_key(&player)
    }

    pub(crate) fn state(&self, player: PlayerId) -> Option<PlayerState> {
        self.players.get(&player).map(|p| p.state)
    }

    pub(crate) fn create(&mut self, player: PlayerId) -> ApplyOp {
        assert!(player.0 != 0, "kaya: player id 0 is reserved for \"no player\"");
        self.released.remove(&player);
        let clash = self.players.insert(player, Player::new()).is_some();
        assert!(!clash, "kaya: player {} already exists — release it first", player.0);
        ApplyOp::CreatePlayer(player)
    }

    fn live_mut(&mut self, player: PlayerId, what: &str) -> &mut Player {
        self.players.get_mut(&player).unwrap_or_else(|| {
            panic!("kaya: {what} names player {}, which is not live — create_player first", player.0)
        })
    }

    pub(crate) fn set_prop(
        &mut self,
        player: PlayerId,
        prop: PlayerProp,
        value: Value,
        out: &mut Vec<ApplyOp>,
        published: &mut Vec<Occurrence>,
    ) {
        let now = self.now();
        let p = self.live_mut(player, "set_player_prop");
        match (prop, value) {
            (PlayerProp::Source, value @ (Value::Str(_) | Value::I64(_))) => {
                let resolved = match value {
                    Value::I64(handle) => resolve_picked(&format!("player {}", player.0), handle),
                    Value::Str(source) => resolve_source(&source),
                    _ => unreachable!(),
                };
                let url = match &resolved {
                    Resolved::Url { url, .. } => url.clone(),
                    _ => String::new(),
                };
                p.failure = None;
                p.detail.clear();
                p.duration_ms = 0;
                p.size = (0, 0);
                p.early_rate = false;
                p.seeks = 0;
                p.opened_at = Some(now);
                p.seek_wait = None;
                p.platform = PlayerTracks::default();
                match resolved {
                    Resolved::None => p.state = PlayerState::Idle,
                    Resolved::Url { .. } => p.state = PlayerState::Loading,
                    Resolved::Refused(failure, detail) => {
                        p.state = PlayerState::Failed;
                        p.failure = Some(failure);
                        p.detail = detail;
                    }
                }
                published.push(changed(player, p));
                p.publish_tracks(player, published);
                if !p.sidecar_selected {
                    p.publish_cue(player, String::new(), published);
                }
                out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::Str(url) });
            }
            (PlayerProp::Captions, Value::I64(handle)) => {
                if p.sidecar_fetch.take().is_some() {
                    out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::Str(String::new()) });
                }
                p.sidecar = Some(read_picked_sidecar(player, handle));
                p.publish_tracks(player, published);
                out.push(p.caption_times(player));
            }
            (PlayerProp::Captions, Value::Str(source)) => {
                let remote = is_remote(&source);
                if p.sidecar_fetch.take().is_some() && !remote {
                    out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::Str(String::new()) });
                }
                p.sidecar = if source.is_empty() || remote { None } else { Some(read_sidecar(player, &source)) };
                if remote {
                    p.sidecar_fetch = Some(source.clone());
                    out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::Str(source) });
                }
                if p.sidecar.is_none() && p.sidecar_selected {
                    p.sidecar_selected = false;
                    p.publish_cue(player, String::new(), published);
                }
                p.publish_tracks(player, published);
                out.push(p.caption_times(player));
            }
            (PlayerProp::CaptionsLanguage, Value::Str(tag)) => {
                assert!(
                    !tag.trim().is_empty(),
                    "kaya: player {} captions_language is a BCP 47 tag (\"en\", \"pt-BR\"), got an empty one",
                    player.0
                );
                p.sidecar_language = tag;
                p.publish_tracks(player, published);
            }
            (PlayerProp::Speed, Value::F64(x)) => {
                assert!(
                    x.is_finite() && x > 0.0,
                    "kaya: player {} speed {x} — a rate is finite and above 0 (pause is a command)",
                    player.0
                );
                out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::F64(x) });
            }
            (PlayerProp::Volume, Value::F64(x)) => {
                assert!(
                    (0.0..=1.0).contains(&x),
                    "kaya: player {} volume {x} — volume is 0..=1, relative to the system volume",
                    player.0
                );
                out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::F64(x) });
            }
            (PlayerProp::Loop, Value::Bool(on)) => {
                p.looping = on;
                out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::Bool(on) });
            }
            (PlayerProp::Muted, Value::Bool(on)) => {
                out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::Bool(on) });
            }
            (prop, value) => panic!(
                "kaya: player {} {prop:?} got {value:?} — source and captions are Str or a picked \
                 file's I64 handle, captions_language Str, speed and volume F64, muted and loop \
                 Bool (spec::PLAYER_PROPS)",
                player.0
            ),
        }
    }

    pub(crate) fn command(&mut self, player: PlayerId, command: PlayerCommand, out: &mut Vec<ApplyOp>) {
        let now = self.now();
        let p = self.live_mut(player, "player_command");
        match command {
            PlayerCommand::Play if p.state == PlayerState::Ended => {
                out.push(ApplyOp::PlayerCommand { player, command: PlayerCommand::Seek(0) });
            }
            PlayerCommand::Seek(to) => {
                p.seeks += 1;
                p.seek_wait = Some((now, to));
            }
            _ => {}
        }
        out.push(ApplyOp::PlayerCommand { player, command });
    }

    /// select_track (docs/media-plan.md §3): a platform track goes to the
    /// platform, a sidecar's caption track is the core's own, and selecting
    /// either caption source turns the other off.
    pub(crate) fn select(
        &mut self,
        player: PlayerId,
        kind: TrackKind,
        index: u32,
        out: &mut Vec<ApplyOp>,
        published: &mut Vec<Occurrence>,
    ) {
        let p = self.live_mut(player, "select_track");
        let listing = p.tracks();
        match kind {
            TrackKind::Audio => {
                assert!(
                    index >= 1 && index as usize <= listing.audio.len(),
                    "kaya: select_track asks audio track {index} of player {}, whose audio tracks \
                     are {:?} (counting from 1)",
                    player.0,
                    listing.audio
                );
                out.push(ApplyOp::SelectTrack { player, kind, index });
            }
            TrackKind::Caption => {
                assert!(
                    index as usize <= listing.captions.len(),
                    "kaya: select_track asks caption track {index} of player {}, whose caption \
                     tracks are {:?} (counting from 1, 0 for none)",
                    player.0,
                    listing.captions
                );
                let sidecar = p.sidecar.is_some() && index as usize == listing.captions.len();
                let was = p.sidecar_selected;
                p.sidecar_selected = sidecar;
                out.push(ApplyOp::SelectTrack { player, kind, index: if sidecar { 0 } else { index } });
                if sidecar != was {
                    out.push(p.caption_times(player));
                }
                if was && !sidecar {
                    p.publish_cue(player, String::new(), published);
                }
                p.publish_tracks(player, published);
            }
        }
    }

    /// The sidecar's cue at the backend's clock time, published when it
    /// changed; "" when no sidecar track is selected.
    pub(crate) fn caption_at(&mut self, player: PlayerId, t_ms: u64) -> (String, Vec<Occurrence>) {
        let mut out = Vec::new();
        let Some(p) = self.players.get_mut(&player) else {
            return (String::new(), out);
        };
        let text = match (&p.sidecar, p.sidecar_selected) {
            (Some(c), true) => c.text_at(t_ms),
            _ => return (String::new(), out),
        };
        p.publish_cue(player, text.clone(), &mut out);
        (text, out)
    }

    #[cfg(feature = "harness")]
    pub(crate) fn caption_snapshot(&self, player: PlayerId, t_ms: Option<u64>) -> Option<CaptionSnapshot> {
        let p = self.players.get(&player)?;
        Some(CaptionSnapshot {
            state: p.state,
            duration_ms: p.duration_ms,
            sidecar: p.sidecar.is_some(),
            selected: p.sidecar_selected,
            boundaries: p.sidecar.as_ref().map_or_else(Vec::new, Captions::boundaries),
            sidecar_expected: t_ms.map(|t| match (&p.sidecar, p.sidecar_selected) {
                (Some(c), true) => c.text_at(t),
                _ => String::new(),
            }),
            published: p.cue.clone(),
        })
    }

    /// The core handed a held source to the platform (docs/media-plan.md
    /// §7d): the open's bound, and a held seek's, run from now.
    pub(crate) fn handed_over(&mut self, player: PlayerId) {
        let now = self.now();
        if let Some(p) = self.players.get_mut(&player) {
            if p.state == PlayerState::Loading {
                p.opened_at = Some(now);
            }
            if let Some((_, to)) = p.seek_wait {
                p.seek_wait = Some((now, to));
            }
        }
    }

    pub(crate) fn was_released(&self, player: PlayerId) -> bool {
        self.released.contains(&player)
    }

    pub(crate) fn release(&mut self, player: PlayerId, out: &mut Vec<ApplyOp>) {
        assert!(
            self.players.remove(&player).is_some(),
            "kaya: release_player names player {}, which is not live",
            player.0
        );
        self.released.insert(player);
        out.push(ApplyOp::ReleasePlayer(player));
        if self.session.player == Some(player) {
            self.session.player = None;
            out.push(self.session_op());
        }
    }

    pub(crate) fn set_session(&mut self, spec: SessionSpec, out: &mut Vec<ApplyOp>) {
        if let Some(player) = spec.player {
            assert!(
                self.is_live(player),
                "kaya: set_session attaches player {}, which is not live — create_player first",
                player.0
            );
        }
        let known = crate::wire::SESSION_ACTIONS.iter().fold(0u32, |m, (v, _)| m | 1 << v);
        assert!(
            spec.actions & !known == 0,
            "kaya: set_session's actions mask {:#x} names no session_action outside {known:#x}",
            spec.actions
        );
        self.session = spec;
        out.push(self.session_op());
    }

    /// The actions the system may send: the app's handlers, plus the
    /// attached player's defaults.
    pub(crate) fn offered(&self) -> u32 {
        let defaults = match self.session.player {
            Some(p) if self.is_live(p) => default_bits(),
            _ => 0,
        };
        self.session.actions | defaults
    }

    fn session_op(&self) -> ApplyOp {
        let artwork = if self.session.artwork.is_empty() {
            String::new()
        } else {
            match crate::assets::media_locator(&self.session.artwork) {
                Ok(url) => url,
                Err(why) => panic!("kaya: set_session's artwork: {why}"),
            }
        };
        ApplyOp::SetSession {
            player: self.session.player,
            offered: self.offered(),
            playback_state: self.session.playback_state,
            title: self.session.title.clone(),
            artist: self.session.artist.clone(),
            album: self.session.album.clone(),
            artwork,
        }
    }

    /// THE ONE-OWNER RULE: an action goes to the app when it handles it,
    /// else to the attached player for the three defaults, else nowhere.
    pub(crate) fn route(&self, action: SessionAction) -> Route {
        if self.session.actions & bit(action) != 0 {
            return Route::App;
        }
        let Some(player) = self.session.player.filter(|p| self.is_live(*p)) else {
            return Route::NotOffered;
        };
        match action {
            SessionAction::Play if self.state(player) == Some(PlayerState::Ended) => Route::Replay(player),
            SessionAction::Play => Route::Player(player, PlayerCommand::Play),
            SessionAction::Pause => Route::Player(player, PlayerCommand::Pause),
            SessionAction::SeekTo(at) => Route::Player(player, PlayerCommand::Seek(at)),
            _ => Route::NotOffered,
        }
    }

    /// What the system's playback state reads: the attached player's, or
    /// what the app stated while none is attached. 0 stopped, 1 playing,
    /// 2 paused.
    pub(crate) fn system_state(&self) -> u32 {
        match self.session.player.and_then(|p| self.state(p)) {
            Some(PlayerState::Playing) => 1,
            Some(PlayerState::Loading | PlayerState::Ready | PlayerState::Paused | PlayerState::Ended) => 2,
            Some(PlayerState::Idle | PlayerState::Failed) => 0,
            None => match self.session.playback_state {
                PlaybackState::None => 0,
                PlaybackState::Playing => 1,
                PlaybackState::Paused => 2,
            },
        }
    }

    /// RULE 1, one state machine: what `report` does to the player, and
    /// what the app hears. A report for a released player, or one its
    /// state has no transition for, changes nothing and publishes nothing.
    pub(crate) fn report(&mut self, player: PlayerId, report: Report) -> Vec<Occurrence> {
        let others_open = self.players.iter().filter(|(id, q)| **id != player && q.is_open()).count();
        let now = self.now();
        let Some(p) = self.players.get_mut(&player) else {
            return Vec::new();
        };
        use PlayerState as S;
        let mut out = Vec::new();
        if matches!(report, Report::Seeked(_)) {
            p.seek_wait = None;
        }
        let past = |since: std::time::Instant| {
            now.saturating_duration_since(since).as_millis() as u64 + TIMEOUT_SLACK_MS >= TIMEOUT_MS
        };
        match (p.state, report) {
            (S::Loading, Report::Loaded { duration_ms, size, undecodable, detail }) => {
                p.duration_ms = duration_ms;
                p.size = size;
                if undecodable {
                    p.state = S::Failed;
                    p.failure = Some(MediaFailure::UnsupportedCodec);
                    p.detail = detail;
                    out.push(changed(player, p));
                } else {
                    p.state = S::Ready;
                    out.push(changed(player, p));
                    if std::mem::take(&mut p.early_rate) {
                        p.state = S::Playing;
                        out.push(changed(player, p));
                    }
                }
            }
            (S::Loading, Report::Rate(on)) => p.early_rate = on,
            (S::Ready | S::Paused | S::Ended, Report::Rate(true)) => {
                p.state = S::Playing;
                out.push(changed(player, p));
            }
            (S::Playing, Report::Rate(false)) => {
                p.state = S::Paused;
                out.push(changed(player, p));
            }
            (S::Playing | S::Paused, Report::Ended) if !p.looping => {
                p.state = S::Ended;
                out.push(changed(player, p));
            }
            (S::Loading | S::Ready | S::Playing | S::Paused | S::Ended, Report::Failed { domain, code, underlying, detail }) => {
                p.failure = Some(if decoder_never_started(&domain, code, p.state, others_open) {
                    MediaFailure::Resources
                } else {
                    failure_reason(&domain, code, underlying)
                });
                p.state = S::Failed;
                p.detail = if detail.is_empty() { format!("{domain} {code}") } else { detail };
                out.push(changed(player, p));
            }
            (S::Loading, Report::Overdue) if p.opened_at.is_some_and(past) => {
                p.state = S::Failed;
                p.failure = Some(MediaFailure::Timeout);
                p.detail = format!(
                    "kaya: the source did not open within {TIMEOUT_MS} ms, and the platform reported \
                     neither readiness nor a failure"
                );
                out.push(changed(player, p));
            }
            (S::Ready | S::Playing | S::Paused | S::Ended, Report::Overdue)
                if p.seek_wait.is_some_and(|(since, _)| past(since)) =>
            {
                let to = p.seek_wait.take().map_or(0, |(_, to)| to);
                p.state = S::Failed;
                p.failure = Some(MediaFailure::Timeout);
                p.detail = format!(
                    "kaya: the seek to {to} ms did not complete within {TIMEOUT_MS} ms, and the platform \
                     reported neither its completion nor a failure"
                );
                out.push(changed(player, p));
            }
            (S::Ready | S::Playing | S::Paused | S::Ended, Report::Position(ms)) => {
                out.push(Occurrence::PlayerPosition { player, position_ms: ms });
            }
            (_, Report::Tracks { audio, captions, audio_selected, caption_selected }) => {
                p.platform = PlayerTracks { audio, captions, audio_selected, caption_selected };
                p.publish_tracks(player, &mut out);
            }
            (_, Report::Cue(text)) if !p.sidecar_selected => p.publish_cue(player, text, &mut out),
            (_, Report::CaptionsText { url, text }) if p.sidecar_fetch.as_deref() == Some(url.as_str()) => {
                p.sidecar_fetch = None;
                match Captions::parse(&text) {
                    Ok(c) => {
                        p.sidecar = Some(c);
                        p.publish_tracks(player, &mut out);
                    }
                    Err(why) if p.state != S::Failed => {
                        p.state = S::Failed;
                        p.failure = Some(MediaFailure::DecodeError);
                        p.detail = format!("kaya: captions {url}: {why}");
                        out.push(changed(player, p));
                    }
                    Err(_) => {}
                }
            }
            (state, Report::CaptionsFailed { url, domain, code, underlying, detail })
                if p.sidecar_fetch.as_deref() == Some(url.as_str()) =>
            {
                p.sidecar_fetch = None;
                if state != S::Failed {
                    p.state = S::Failed;
                    p.failure = Some(failure_reason(&domain, code, underlying));
                    p.detail = if detail.is_empty() {
                        format!("kaya: captions {url}: {domain} {code}")
                    } else {
                        format!("kaya: captions {url}: {detail}")
                    };
                    out.push(changed(player, p));
                }
            }
            (S::Ready | S::Playing | S::Paused | S::Ended, Report::Seeked(ms)) if p.seeks > 0 => {
                p.seeks -= 1;
                if p.state == S::Ended {
                    p.state = S::Paused;
                    out.push(changed(player, p));
                }
                out.push(Occurrence::SeekCompleted { player, position_ms: ms });
            }
            _ => {}
        }
        out
    }
}

/// Whether a report's answer failed the player `timeout`: the backend's cue
/// to tear its item down (docs/media-plan.md §7c).
pub(crate) fn timed_out(published: &[Occurrence]) -> bool {
    published.iter().any(|o| {
        matches!(o, Occurrence::PlayerChanged { state: PlayerState::Failed, failure: Some(MediaFailure::Timeout), .. })
    })
}

fn changed(player: PlayerId, p: &Player) -> Occurrence {
    Occurrence::PlayerChanged {
        player,
        state: p.state,
        failure: p.failure,
        duration_ms: p.duration_ms,
        width: p.size.0,
        height: p.size.1,
        detail: p.detail.clone(),
    }
}

/// GStreamer's `missing-plugin` element message, as the GTK arm reports it:
/// this prefix, then the media type of the caps nothing could handle.
pub(crate) const GST_MISSING_PLUGIN: &str = "missing-plugin:";

/// A GStreamer error's `underlying` when the element that posted it is a
/// network source (klass Source/Network): a refused, unresolvable or
/// unroutable connection is a stream error from that element alone
/// (docs/probes/media-suite-2026-09-29.md).
pub(crate) const GST_FROM_NETWORK_SOURCE: i64 = 1;

/// Whether a missing-plugin message's caps name a container or a manifest
/// (a demuxer was missing) rather than a codec.
pub(crate) fn gst_container_caps(media_type: &str) -> bool {
    matches!(
        media_type,
        "video/quicktime"
            | "video/x-matroska"
            | "video/webm"
            | "audio/webm"
            | "video/mpegts"
            | "application/ogg"
            | "audio/ogg"
            | "video/ogg"
            | "audio/x-wav"
            | "video/x-msvideo"
            | "video/x-flv"
            | "application/x-hls"
            | "application/dash+xml"
            | "application/vnd.ms-sstr+xml"
    )
}

/// THE FAILURE TABLE (docs/media-plan.md §7a): a platform's error, as its
/// domain and codes, to the closed reason. `kaya` is a backend's own
/// classification (the MEDIA_FAILURE value as the code); `http` a status.
pub(crate) fn failure_reason(domain: &str, code: i64, underlying: i64) -> MediaFailure {
    use MediaFailure as F;
    match (domain, code, underlying) {
        ("kaya", c, _) => crate::wire::media_failure_from(c as u32).unwrap_or(F::DecodeError),
        ("http", 404 | 410, _) => F::NotFound,
        ("http", _, _) => F::Network,
        ("AVFoundationErrorDomain", -11828, _) => F::UnsupportedContainer,
        ("AVFoundationErrorDomain", _, -12847) => F::UnsupportedContainer,
        ("AVFoundationErrorDomain", -11821, _) => F::DecodeError,
        ("AVFoundationErrorDomain", -11839, _) => F::Resources,
        ("AVFoundationErrorDomain", _, -12913) => F::Resources,
        ("AVFoundationErrorDomain", -11850, _) => F::Network,
        ("AVFoundationErrorDomain", _, -17913) => F::NotFound,
        ("NSURLErrorDomain", -1100, _) => F::NotFound,
        ("NSURLErrorDomain", _, _) => F::Network,
        ("CoreMediaErrorDomain", -12938, _) => F::NotFound,
        ("CoreMediaErrorDomain", -12847, _) => F::UnsupportedContainer,
        // media3's PlaybackException.errorCode, the HTTP status beneath 2004.
        ("media3", 4004 | 4005, _) => F::UnsupportedCodec,
        ("media3", 3003 | 3004, _) => F::UnsupportedContainer,
        ("media3", 2005, _) => F::NotFound,
        ("media3", 2004, 404 | 410) => F::NotFound,
        ("media3", 2001 | 2002 | 2004, _) => F::Network,
        // MediaCodec.CodecException's ERROR_INSUFFICIENT_RESOURCE and
        // ERROR_RECLAIMED, and media3's reclaimed code: the platform's own
        // resource signals (docs/traps.md, the emulator pool's 15th player).
        ("media3", 4001 | 4003, 1100 | 1101) => F::Resources,
        ("media3", 4006, _) => F::Resources,
        ("media3", 4001 | 4003 | 3001 | 3002, _) => F::DecodeError,
        // GStreamer's GError quarks and codes, and the missing-plugin
        // message's caps (the GTK arm).
        (d, _, _) if d.starts_with(GST_MISSING_PLUGIN) => {
            if gst_container_caps(&d[GST_MISSING_PLUGIN.len()..]) {
                F::UnsupportedContainer
            } else {
                F::UnsupportedCodec
            }
        }
        ("gst-stream-error-quark", 6, _) => F::UnsupportedCodec,
        ("gst-stream-error-quark", 4 | 5 | 9, _) => F::UnsupportedContainer,
        ("gst-stream-error-quark", 7, _) => F::DecodeError,
        ("gst-stream-error-quark", 1, GST_FROM_NETWORK_SOURCE) => F::Network,
        ("gst-resource-error-quark", 3, _) => F::NotFound,
        ("gst-resource-error-quark", _, GST_FROM_NETWORK_SOURCE) => F::Network,
        // WinUI's MediaPlayerError (2 NetworkError, 3 DecodingError, 4
        // SourceNotSupported) over its ExtendedErrorCode: one
        // SourceNotSupported for a refused port, a 404 and an unknown
        // container alike, told apart by the HRESULT (measured,
        // docs/probes/media-suite-2026-09-29.md).
        ("MediaPlayerError", 4, WIN_UNSUPPORTED_BYTESTREAM | WIN_UNSUPPORTED_MANIFEST) => F::UnsupportedContainer,
        ("MediaPlayerError", 4, WIN_FILE_NOT_FOUND) => F::NotFound,
        ("MediaPlayerError", 4, WIN_SERVER_NOT_FOUND) => F::Network,
        ("MediaPlayerError", 2, _) => F::Network,
        ("MediaPlayerError", 3, _) => F::DecodeError,
        // The Compose reader's names for the exception each platform call
        // threw (KayaReader.kt's READER_* codes).
        ("android.reader", 1, _) => F::UnsupportedContainer,
        ("android.reader", 2, _) => F::NotFound,
        ("android.reader", 3, _) => F::UnsupportedCodec,
        // Media Foundation's HRESULT under the WinUI reader (winui/reader.rs),
        // as u32.
        ("MediaFoundation", WIN_UNSUPPORTED_BYTESTREAM | WIN_UNSUPPORTED_MANIFEST, _) => F::UnsupportedContainer,
        ("MediaFoundation", WIN_FILE_NOT_FOUND | WIN_PATH_NOT_FOUND | WIN_ERROR_FILE_NOT_FOUND, _) => F::NotFound,
        ("MediaFoundation", WIN_SERVER_NOT_FOUND, _) => F::Network,
        ("MediaFoundation", WIN_CODEC_NOT_FOUND | WIN_INVALID_MEDIA_TYPE, _) => F::UnsupportedCodec,
        // A transport failure of the HTTP client a WinUI sidecar is fetched
        // with; a status arrives as `http`.
        ("Windows.Web.Http", _, _) => F::Network,
        // A WinUI adaptive source that could not be created, its HTTP status
        // as the underlying (winui/media.rs adaptive_created): 1 is
        // ManifestDownloadFailure, 2-5 a manifest it cannot read.
        ("AdaptiveMediaSourceCreationStatus", 1, 404 | 410) => F::NotFound,
        ("AdaptiveMediaSourceCreationStatus", 1, _) => F::Network,
        ("AdaptiveMediaSourceCreationStatus", 2..=5, _) => F::UnsupportedContainer,
        _ => F::DecodeError,
    }
}

/// RULED 2026-09-30 (the maintainer): media3 reports running out of
/// decoders as a decoder failing (4001, 4003) over the codec's own error
/// (14, -19), never as 1100/1101 (docs/traps.md, the emulator pool's 15th
/// player), so such a failure is `resources` when it comes before the
/// player ever readied and other players are open.
fn decoder_never_started(domain: &str, code: i64, state: PlayerState, others_open: usize) -> bool {
    domain == "media3" && matches!(code, 4001 | 4003) && state == PlayerState::Loading && others_open > 0
}

/// Media Foundation's HRESULTs under WinUI's MediaPlayerError, as u32.
const WIN_UNSUPPORTED_BYTESTREAM: i64 = 0xC00D_36C4;
const WIN_UNSUPPORTED_MANIFEST: i64 = 0xC00D_6591;
const WIN_FILE_NOT_FOUND: i64 = 0xC00D_001A;
const WIN_SERVER_NOT_FOUND: i64 = 0xC00D_0035;
const WIN_PATH_NOT_FOUND: i64 = 0x8007_0003;
const WIN_ERROR_FILE_NOT_FOUND: i64 = 0x8007_0002;
const WIN_CODEC_NOT_FOUND: i64 = 0xC00D_5212;
const WIN_INVALID_MEDIA_TYPE: i64 = 0xC00D_36B4;

/// Where a `source` points, checked before any backend sees it: an asset
/// name through the one resolver, an http(s) URL as written, a picked
/// file's absolute path if it exists. A local source that is not there is
/// `not_found` here, since AVFoundation reports it as -17913, which names
/// nothing (§7a).
pub(crate) fn resolve_source(source: &str) -> Resolved {
    if source.is_empty() {
        return Resolved::None;
    }
    let lower = source.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        if let Some(refusal) = refused_before_load(&lower) {
            return refusal;
        }
        return Resolved::Url { url: source.to_owned() };
    }
    if let Some(refusal) = refused_before_load(&lower) {
        return refusal;
    }
    if std::path::Path::new(source).is_absolute() {
        return if std::path::Path::new(source).is_file() {
            Resolved::Url { url: crate::assets::file_url(std::path::Path::new(source)) }
        } else {
            Resolved::Refused(MediaFailure::NotFound, format!("kaya: no file at {source}"))
        };
    }
    match crate::assets::media_locator(source) {
        Ok(url) => Resolved::Url { url },
        Err(why) => Resolved::Refused(MediaFailure::NotFound, why),
    }
}

/// A picked file as a source (the maintainer's ruling of 2026-09-30): where
/// the platform hands back a path, the path's own check; where it hands back
/// only its own reference (an Android `content://` URI, an iOS URL), that
/// reference as written, for the platform's player to open or fail on.
pub(crate) fn resolve_picked(who: &str, handle: i64) -> Resolved {
    let source = picked(who, "source", handle);
    let local = crate::protocol::PickedSource::local_path(&*source);
    if local.is_empty() {
        Resolved::Url { url: crate::protocol::PickedSource::locator(&*source).to_owned() }
    } else {
        resolve_source(local)
    }
}

pub(crate) fn picked(who: &str, what: &str, handle: i64) -> std::sync::Arc<dyn crate::protocol::PickedSource> {
    crate::capi::picked_source(crate::protocol::PickedId(handle as u64)).unwrap_or_else(|| {
        panic!(
            "kaya: {who} {what} names picked file {handle}, which was never minted — a file \
             handle comes from a picker result"
        )
    })
}

/// A picked sidecar, read through the picked file's own open, which every
/// platform's reference answers.
fn read_picked_sidecar(player: PlayerId, handle: i64) -> Captions {
    use std::io::Read;
    let source = picked(&format!("player {}", player.0), "captions", handle);
    let name = crate::protocol::PickedSource::name(&*source).to_owned();
    let mut bytes = Vec::new();
    source
        .open(crate::protocol::FileMode::Read)
        .and_then(|(raw, _)| unsafe { crate::protocol::file_from_raw(raw) }.read_to_end(&mut bytes))
        .unwrap_or_else(|e| panic!("kaya: player {} captions: the picked file {name:?} would not open: {e}", player.0));
    let text = String::from_utf8(bytes)
        .unwrap_or_else(|_| panic!("kaya: player {} captions {name:?} is not UTF-8, which WebVTT is", player.0));
    Captions::parse(&text).unwrap_or_else(|why| panic!("kaya: player {} captions {name:?}: {why}", player.0))
}

fn is_remote(source: &str) -> bool {
    let lower = source.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// A LOCAL sidecar WebVTT file, read and parsed by the core (docs/media-plan.md
/// §3): an asset name or an absolute path. An http(s) one is
/// fetched by the backend and handed back as Report::CaptionsText.
fn read_sidecar(player: PlayerId, source: &str) -> Captions {
    let bytes = if std::path::Path::new(source).is_absolute() {
        std::fs::read(source).map_err(|e| format!("kaya: no caption file at {source}: {e}"))
    } else {
        crate::assets::read(source)
    }
    .unwrap_or_else(|why| panic!("kaya: player {} captions: {why}", player.0));
    let text = String::from_utf8(bytes)
        .unwrap_or_else(|_| panic!("kaya: player {} captions {source:?} is not UTF-8, which WebVTT is", player.0));
    Captions::parse(&text).unwrap_or_else(|why| panic!("kaya: player {} captions {source:?}: {why}", player.0))
}

/// Which band of visibility a fraction falls in: 0 not shown, 1 to 10 the
/// tenth it shows (anything above 0 is at least 1), 11 shown whole.
fn visibility_band(shown: f64) -> u8 {
    if shown <= 0.0 {
        0
    } else if shown >= 1.0 - 1e-3 {
        11
    } else {
        1 + (shown * 10.0).floor().min(9.0) as u8
    }
}

/// THE VISIBILITY COALESCING (docs/media-plan.md §7b): a backend reports a
/// video view's shown fraction as often as its geometry moves, every frame
/// of a scroll; the app hears it only when the view enters or leaves, when
/// the tenth it shows moves, and when it shows whole.
#[derive(Default)]
pub(crate) struct Visibility {
    bands: HashMap<WidgetId, u8>,
}

impl Visibility {
    /// Some(fraction) when this report is news to the app.
    pub(crate) fn report(&mut self, id: WidgetId, shown: f64) -> Option<f64> {
        let shown = if shown.is_finite() { shown.clamp(0.0, 1.0) } else { 0.0 };
        let band = visibility_band(shown);
        let last = self.bands.get(&id).copied().unwrap_or(0);
        if band == last {
            return None;
        }
        if band == 0 {
            self.bands.remove(&id);
        } else {
            self.bands.insert(id, band);
        }
        Some(shown)
    }

    pub(crate) fn is_shown(&self, id: WidgetId) -> bool {
        self.bands.contains_key(&id)
    }

    /// The view went away: true when the app last heard it shown, so it
    /// hears it leave.
    pub(crate) fn gone(&mut self, id: WidgetId) -> bool {
        self.bands.remove(&id).is_some()
    }
}

/// Apple opens no DASH manifest, and from a server that ignores `Range` it
/// says so as a server error (-11850) before reading the format; so the
/// capability query's answer is given before the load (§7a).
fn refused_before_load(lower: &str) -> Option<Resolved> {
    if cfg!(any(target_os = "macos", target_os = "ios")) {
        let path = lower.split(['?', '#']).next().unwrap_or(lower);
        if path.ends_with(".mpd") {
            return Some(Resolved::Refused(
                MediaFailure::UnsupportedContainer,
                "kaya: AVFoundation plays no DASH manifest".to_owned(),
            ));
        }
    }
    None
}

/// The capability query (docs/media-plan.md §8 ruling 1): true exactly
/// when a source of this type would not fail as unsupported_codec or
/// unsupported_container, so what the core refuses before a load it
/// refuses here too.
pub(crate) fn can_play(mime: &str, codecs: &str) -> bool {
    let mime = mime.trim().to_ascii_lowercase();
    if cfg!(any(target_os = "macos", target_os = "ios")) && mime == "application/dash+xml" {
        return false;
    }
    platform_can_play(&mime, codecs.trim())
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn platform_can_play(mime: &str, codecs: &str) -> bool {
    crate::swiftui_host::can_play(mime, codecs).unwrap_or_else(|| {
        panic!(
            "kaya: can_play({mime:?}, {codecs:?}) asks the SwiftUI backend, and the one loaded \
             exports no kaya_swiftui_can_play — rebuild it (tools/swiftui/build-dylib.sh)"
        )
    })
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn platform_can_play(mime: &str, codecs: &str) -> bool {
    crate::backend::can_play(mime, codecs)
}

#[cfg(target_os = "android")]
fn platform_can_play(mime: &str, codecs: &str) -> bool {
    crate::android::can_play(mime, codecs)
}

/// A video view's height for the width it is laid out at: its natural
/// size's aspect, the player's and the self-view's alike (docs/media-plan.md
/// §3). A view that does not grow is no wider than its natural width.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn video_view_height(natural: (u32, u32), width: i32, grows: bool) -> i32 {
    let (w, h) = (i64::from(natural.0.max(1)), i64::from(natural.1));
    let width = if grows { i64::from(width.max(0)) } else { i64::from(width.max(0)).min(w) };
    ((width * h + w / 2) / w) as i32
}

/// What a video view shows, as its box rule reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum VideoPicture {
    /// A player's picture at its natural size (the arm's placeholder until known).
    Player((u32, u32)),
    /// A capture's self-view: its frames as they arrive (0x0 with no camera)
    /// and the clockwise rotation they carry.
    SelfView { frames: (u32, u32), rotation: u32 },
}

/// A video view's box before layout (docs/media-plan.md §3, RULED
/// 2026-10-03): its picture's natural size, or with an `aspect` the app set
/// (the wire's packed I64, 0 for none) the picture's LONGER side at its
/// natural scale for the width, whatever its rotation, at that ratio.
/// `video_view_height` lays out whatever this answers.
pub(crate) fn video_view_box(picture: VideoPicture, aspect: i64) -> (u32, u32) {
    let (natural, scale) = match picture {
        VideoPicture::Player(natural) => (natural, natural),
        VideoPicture::SelfView { frames, rotation } => {
            (crate::capture::self_view_natural(frames, rotation), crate::capture::self_view_scale(frames))
        }
    };
    let Ok(a) = crate::protocol::Aspect::from_packed(aspect) else {
        return natural;
    };
    let width = scale.0.max(scale.1);
    let (w, aw, ah) = (u64::from(width), u64::from(a.width), u64::from(a.height));
    (width, ((w * ah + aw / 2) / aw).clamp(1, u64::from(u32::MAX)) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_aspect_sets_the_box_and_nothing_else_does() {
        let pack = crate::protocol::Aspect::pack;
        let player = VideoPicture::Player;
        let camera = |frames, rotation| VideoPicture::SelfView { frames, rotation };
        assert_eq!(video_view_box(player((320, 240)), 0), (320, 240));
        assert_eq!(video_view_box(player((180, 240)), 0), (180, 240));
        assert_eq!(video_view_box(player((320, 240)), pack(16, 9)), (320, 180));
        assert_eq!(video_view_box(player((180, 240)), pack(16, 9)), (240, 135));
        assert_eq!(video_view_box(player((640, 360)), pack(1, 1)), (640, 640));
        assert_eq!(video_view_box(player((640, 360)), pack(65535, 1)), (640, 1));
        assert_eq!(video_view_box(player((320, 240)), pack(0, 9)), (320, 240));
        assert_eq!(video_view_box(camera((640, 480), 0), 0), (320, 240));
        assert_eq!(video_view_box(camera((640, 480), 90), 0), (180, 240));
        assert_eq!(video_view_box(camera((0, 0), 90), 0), (320, 240));
        for rotation in [0, 90, 180, 270] {
            assert_eq!(video_view_box(camera((640, 480), rotation), pack(16, 9)), (320, 180), "{rotation}");
            assert_eq!(video_view_box(camera((480, 640), rotation), pack(16, 9)), (320, 180), "{rotation}");
            assert_eq!(video_view_box(camera((1280, 720), rotation), pack(16, 9)), (640, 360), "{rotation}");
            assert_eq!(video_view_box(camera((0, 0), rotation), pack(16, 9)), (320, 180), "{rotation}");
        }
        let (w, h) = video_view_box(player((320, 240)), pack(16, 9));
        assert_eq!(video_view_height((w, h), 160, false), 90);
        assert_eq!(video_view_height((w, h), 900, true), 506);
    }

    #[test]
    fn an_aspect_packs_both_parts_signed_and_refuses_each_by_name() {
        use crate::protocol::Aspect;
        assert_eq!(Aspect::pack(16, 9), (16 << 32) | 9);
        assert_eq!(Aspect::from_packed(Aspect::pack(16, 9)), Ok(Aspect { width: 16, height: 9 }));
        assert_eq!(Aspect::from_packed(Aspect::pack(65535, 1)), Ok(Aspect { width: 65535, height: 1 }));
        for (w, h, said) in [
            (0, 9, "aspect 0:9 has a width of 0"),
            (16, 0, "aspect 16:0 has a height of 0"),
            (0, 0, "aspect 0:0 has a width of 0"),
            (-16, 9, "aspect -16:9 has a width of -16"),
            (16, -9, "aspect 16:-9 has a height of -9"),
            (-16, -9, "aspect -16:-9 has a width of -16"),
            (65536, 9, "aspect 65536:9 has a width of 65536"),
            (1 << 40, 9, "aspect 2147483647:9 has a width of 2147483647"),
            (16, -(1 << 40), "aspect 16:-2147483648 has a height of -2147483648"),
        ] {
            let why = Aspect::from_packed(Aspect::pack(w, h)).unwrap_err();
            assert!(why.starts_with(said), "{w}:{h} said {why:?}, wanted it to start {said:?}");
        }
    }

    #[test]
    fn a_video_view_keeps_its_aspect_as_it_shrinks() {
        assert_eq!(video_view_height((640, 360), 640, false), 360);
        assert_eq!(video_view_height((640, 360), 488, false), 275);
        assert_eq!(video_view_height((640, 360), 900, false), 360);
        assert_eq!(video_view_height((640, 360), 900, true), 506);
        assert_eq!(video_view_height((320, 240), 0, false), 0);
        assert_eq!(video_view_height((0, 0), 300, true), 0);
    }

    const P: PlayerId = PlayerId(7);

    fn loaded(undecodable: bool) -> Report {
        Report::Loaded { duration_ms: 2000, size: (160, 90), undecodable, detail: "a track".into() }
    }

    fn states(occs: &[Occurrence]) -> Vec<PlayerState> {
        occs.iter()
            .filter_map(|o| match o {
                Occurrence::PlayerChanged { state, .. } => Some(*state),
                _ => None,
            })
            .collect()
    }

    fn with_source(source: &str) -> (Media, Vec<ApplyOp>, Vec<Occurrence>) {
        let mut m = Media::default();
        let mut out = vec![m.create(P)];
        let mut published = Vec::new();
        m.set_prop(P, PlayerProp::Source, Value::Str(source.into()), &mut out, &mut published);
        (m, out, published)
    }

    #[test]
    fn a_source_loads_then_readies_then_plays_pauses_and_ends() {
        let (mut m, _, published) = with_source("media/h264_aac.mp4");
        assert_eq!(states(&published), [PlayerState::Loading]);
        assert_eq!(states(&m.report(P, loaded(false))), [PlayerState::Ready]);
        assert_eq!(states(&m.report(P, Report::Rate(true))), [PlayerState::Playing]);
        assert_eq!(states(&m.report(P, Report::Rate(false))), [PlayerState::Paused]);
        assert_eq!(states(&m.report(P, Report::Rate(true))), [PlayerState::Playing]);
        assert_eq!(states(&m.report(P, Report::Ended)), [PlayerState::Ended]);
        // Nothing moves an ended player but a play.
        assert!(m.report(P, Report::Rate(false)).is_empty());
    }

    #[test]
    fn a_rate_that_beats_the_load_plays_once_ready() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        assert!(m.report(P, Report::Rate(true)).is_empty());
        assert_eq!(states(&m.report(P, loaded(false))), [PlayerState::Ready, PlayerState::Playing]);
    }

    #[test]
    fn an_undecodable_track_fails_the_player_as_unsupported_codec() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        let occs = m.report(P, loaded(true));
        assert!(matches!(
            occs.as_slice(),
            [Occurrence::PlayerChanged {
                state: PlayerState::Failed,
                failure: Some(MediaFailure::UnsupportedCodec),
                ..
            }]
        ));
        // Failed is terminal until the next source: the audio playing on
        // is not the app's news.
        assert!(m.report(P, Report::Rate(true)).is_empty());
        assert!(m.report(P, Report::Ended).is_empty());
    }

    #[test]
    fn a_looping_player_never_ends() {
        let (mut m, mut out, mut published) = with_source("media/h264_aac.mp4");
        m.set_prop(P, PlayerProp::Loop, Value::Bool(true), &mut out, &mut published);
        m.report(P, loaded(false));
        m.report(P, Report::Rate(true));
        assert!(m.report(P, Report::Ended).is_empty());
        assert_eq!(m.state(P), Some(PlayerState::Playing));
    }

    #[test]
    fn play_after_ended_seeks_to_the_start_first() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.report(P, loaded(false));
        m.report(P, Report::Rate(true));
        m.report(P, Report::Ended);
        let mut out = Vec::new();
        m.command(P, PlayerCommand::Play, &mut out);
        assert_eq!(
            out,
            [
                ApplyOp::PlayerCommand { player: P, command: PlayerCommand::Seek(0) },
                ApplyOp::PlayerCommand { player: P, command: PlayerCommand::Play },
            ]
        );
        // The core's own seek is not the app's: no seek_completed.
        assert!(m.report(P, Report::Seeked(0)).is_empty());
    }

    #[test]
    fn only_the_apps_seeks_complete() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.report(P, loaded(false));
        let mut out = Vec::new();
        m.command(P, PlayerCommand::Seek(1500), &mut out);
        assert_eq!(
            m.report(P, Report::Seeked(1500)),
            [Occurrence::SeekCompleted { player: P, position_ms: 1500 }]
        );
        assert!(m.report(P, Report::Seeked(1500)).is_empty());
    }

    #[test]
    fn a_missing_local_source_is_not_found_before_the_platform_sees_it() {
        let (m, out, published) = with_source("media/nope.mp4");
        assert!(matches!(
            published.as_slice(),
            [Occurrence::PlayerChanged {
                state: PlayerState::Failed,
                failure: Some(MediaFailure::NotFound),
                ..
            }]
        ));
        assert!(out.contains(&ApplyOp::SetPlayerProp {
            player: P,
            prop: PlayerProp::Source,
            value: Value::Str(String::new()),
        }));
        assert_eq!(m.state(P), Some(PlayerState::Failed));
        let (_, _, published) = with_source("/definitely/not/here.mp4");
        assert!(matches!(
            published.as_slice(),
            [Occurrence::PlayerChanged { failure: Some(MediaFailure::NotFound), .. }]
        ));
    }

    #[test]
    fn a_found_asset_is_handed_over_as_a_file_url_and_a_stream_as_written() {
        let (_, out, _) = with_source("media/h264_aac.mp4");
        let url = out
            .iter()
            .find_map(|op| match op {
                ApplyOp::SetPlayerProp { value: Value::Str(s), .. } => Some(s.clone()),
                _ => None,
            })
            .unwrap();
        assert!(url.starts_with("file://") && url.ends_with("/media/h264_aac.mp4"), "{url}");
        assert_eq!(
            resolve_source("https://example.invalid/a.m3u8"),
            Resolved::Url { url: "https://example.invalid/a.m3u8".into() }
        );
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    #[test]
    fn apple_refuses_a_dash_manifest_before_loading_it() {
        assert!(matches!(
            resolve_source("http://127.0.0.1:8765/dash.mpd"),
            Resolved::Refused(MediaFailure::UnsupportedContainer, _)
        ));
    }

    fn pass(m: &mut Media, ms: u64) {
        m.skew += std::time::Duration::from_millis(ms);
    }

    #[test]
    fn an_open_past_the_bound_fails_timeout_whatever_the_source() {
        for source in ["media/h264_aac.mp4", "http://127.0.0.1:8765/hls_mpegts.m3u8"] {
            let (mut m, _, _) = with_source(source);
            pass(&mut m, TIMEOUT_MS - TIMEOUT_SLACK_MS - 1000);
            assert!(m.report(P, Report::Overdue).is_empty(), "{source}: a wake before the bound");
            pass(&mut m, 1000);
            let occs = m.report(P, Report::Overdue);
            assert_eq!(failure(&occs), Some(MediaFailure::Timeout), "{source}");
            assert!(timed_out(&occs));
            assert_eq!(m.state(P), Some(PlayerState::Failed));
            // The platform's late answer is not the app's news.
            assert!(m.report(P, loaded(false)).is_empty());
        }
    }

    #[test]
    fn a_new_source_restarts_the_open_bound() {
        let (mut m, mut out, mut published) = with_source("media/h264_aac.mp4");
        pass(&mut m, TIMEOUT_MS / 2);
        m.set_prop(P, PlayerProp::Source, Value::Str("media/tone.mp3".into()), &mut out, &mut published);
        pass(&mut m, TIMEOUT_MS / 2 + 1000);
        assert!(m.report(P, Report::Overdue).is_empty(), "the first source's wake, the second's clock");
        pass(&mut m, TIMEOUT_MS);
        assert_eq!(failure(&m.report(P, Report::Overdue)), Some(MediaFailure::Timeout));
    }

    #[test]
    fn a_player_that_opened_is_past_the_open_bound() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.report(P, loaded(false));
        pass(&mut m, TIMEOUT_MS * 2);
        assert!(m.report(P, Report::Overdue).is_empty());
        assert_eq!(m.state(P), Some(PlayerState::Ready));
    }

    #[test]
    fn an_apps_seek_past_the_bound_fails_timeout() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.report(P, loaded(false));
        let mut out = Vec::new();
        m.command(P, PlayerCommand::Seek(500), &mut out);
        pass(&mut m, TIMEOUT_MS - TIMEOUT_SLACK_MS - 1000);
        assert!(m.report(P, Report::Overdue).is_empty());
        pass(&mut m, 1000);
        let occs = m.report(P, Report::Overdue);
        assert_eq!(failure(&occs), Some(MediaFailure::Timeout));
        assert!(matches!(
            occs.as_slice(),
            [Occurrence::PlayerChanged { detail, .. }] if detail.contains("seek to 500 ms")
        ));
    }

    #[test]
    fn a_seek_report_ends_the_wait_and_the_latest_seek_restarts_it() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.report(P, loaded(false));
        let mut out = Vec::new();
        m.command(P, PlayerCommand::Seek(500), &mut out);
        m.report(P, Report::Seeked(500));
        pass(&mut m, TIMEOUT_MS * 2);
        assert!(m.report(P, Report::Overdue).is_empty(), "a completed seek waits on nothing");
        // A superseded seek's report never comes (AVFoundation reports only
        // a finished one): the latest seek's report ends the wait.
        m.command(P, PlayerCommand::Seek(100), &mut out);
        pass(&mut m, TIMEOUT_MS / 2);
        m.command(P, PlayerCommand::Seek(1500), &mut out);
        pass(&mut m, TIMEOUT_MS / 2 + 1000);
        assert!(m.report(P, Report::Overdue).is_empty(), "the first seek's wake, the latest seek's clock");
        m.report(P, Report::Seeked(1500));
        pass(&mut m, TIMEOUT_MS);
        assert!(m.report(P, Report::Overdue).is_empty());
        assert_eq!(m.state(P), Some(PlayerState::Ready));
    }

    #[test]
    fn the_cores_own_replay_seek_waits_on_nothing() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.report(P, loaded(false));
        m.report(P, Report::Rate(true));
        m.report(P, Report::Ended);
        let mut out = Vec::new();
        m.command(P, PlayerCommand::Play, &mut out);
        pass(&mut m, TIMEOUT_MS * 2);
        assert!(m.report(P, Report::Overdue).is_empty());
    }

    #[test]
    fn a_released_player_hears_nothing_more() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        let mut out = Vec::new();
        m.release(P, &mut out);
        assert_eq!(out, [ApplyOp::ReleasePlayer(P)]);
        assert!(m.report(P, loaded(false)).is_empty());
    }

    /// The failure table, row by row (docs/media-plan.md §7a, the Apple
    /// column and the two generic domains).
    #[test]
    fn the_failure_table_maps_each_platform_code_to_its_reason() {
        use MediaFailure as F;
        let rows: &[(&str, i64, i64, F)] = &[
            ("AVFoundationErrorDomain", -11828, 0, F::UnsupportedContainer),
            ("AVFoundationErrorDomain", -11828, -12847, F::UnsupportedContainer),
            ("AVFoundationErrorDomain", -11800, -12847, F::UnsupportedContainer),
            ("AVFoundationErrorDomain", -11821, 0, F::DecodeError),
            ("AVFoundationErrorDomain", -11839, 0, F::Resources),
            ("AVFoundationErrorDomain", -11839, -12913, F::Resources),
            ("AVFoundationErrorDomain", -11800, -12913, F::Resources),
            ("kaya", 6, 0, F::Resources),
            ("AVFoundationErrorDomain", -11850, -12939, F::Network),
            ("AVFoundationErrorDomain", -11800, -17913, F::NotFound),
            ("NSURLErrorDomain", -1100, 0, F::NotFound),
            ("NSURLErrorDomain", -1004, 0, F::Network),
            ("NSURLErrorDomain", -1003, 0, F::Network),
            ("CoreMediaErrorDomain", -12938, 0, F::NotFound),
            ("http", 404, 0, F::NotFound),
            ("http", 410, 0, F::NotFound),
            ("http", 503, 0, F::Network),
            ("kaya", 1, 0, F::UnsupportedCodec),
            ("kaya", 2, 0, F::UnsupportedContainer),
            ("somewhere", 1, 2, F::DecodeError),
            ("MediaPlayerError", 4, 0xC00D_36C4, F::UnsupportedContainer),
            ("MediaPlayerError", 4, 0xC00D_6591, F::UnsupportedContainer),
            ("MediaPlayerError", 4, 0xC00D_001A, F::NotFound),
            ("MediaPlayerError", 4, 0xC00D_0035, F::Network),
            ("MediaPlayerError", 2, 0, F::Network),
            ("MediaPlayerError", 3, 0x887A_0022, F::DecodeError),
            ("MediaPlayerError", 4, 0x8000_4005, F::DecodeError),
            ("Windows.Web.Http", 0x8007_2EFD, 0, F::Network),
            ("AdaptiveMediaSourceCreationStatus", 1, 404, F::NotFound),
            ("AdaptiveMediaSourceCreationStatus", 1, 410, F::NotFound),
            ("AdaptiveMediaSourceCreationStatus", 1, 0, F::Network),
            ("AdaptiveMediaSourceCreationStatus", 1, 503, F::Network),
            ("AdaptiveMediaSourceCreationStatus", 2, 200, F::UnsupportedContainer),
            ("AdaptiveMediaSourceCreationStatus", 5, 200, F::UnsupportedContainer),
            ("AdaptiveMediaSourceCreationStatus", 6, 200, F::DecodeError),
            ("media3", 4004, 0, F::UnsupportedCodec),
            ("media3", 4005, 0, F::UnsupportedCodec),
            ("media3", 3003, 0, F::UnsupportedContainer),
            ("media3", 3004, 0, F::UnsupportedContainer),
            ("media3", 2005, 0, F::NotFound),
            ("media3", 2004, 404, F::NotFound),
            ("media3", 2004, 410, F::NotFound),
            ("media3", 2004, 500, F::Network),
            ("media3", 2001, 0, F::Network),
            ("media3", 2002, 0, F::Network),
            ("media3", 4001, 0, F::DecodeError),
            ("media3", 4003, 0, F::DecodeError),
            ("media3", 3001, 0, F::DecodeError),
            ("media3", 3002, 0, F::DecodeError),
            ("media3", 4001, 1100, F::Resources),
            ("media3", 4003, 1101, F::Resources),
            ("media3", 4006, 0, F::Resources),
            ("media3", 4003, 14, F::DecodeError),
        ];
        for (domain, code, underlying, want) in rows {
            assert_eq!(failure_reason(domain, *code, *underlying), *want, "{domain} {code} {underlying}");
        }
    }

    /// The GStreamer column (the GTK arm): GError quark and code, the
    /// network source flag, and a missing-plugin message's caps.
    #[test]
    fn the_failure_table_maps_gstreamer_errors_and_missing_plugins() {
        use MediaFailure as F;
        let net = GST_FROM_NETWORK_SOURCE;
        let rows: &[(&str, i64, i64, F)] = &[
            ("missing-plugin:video/x-av1", 0, 0, F::UnsupportedCodec),
            ("missing-plugin:video/x-h264", 0, 0, F::UnsupportedCodec),
            ("missing-plugin:audio/mpeg", 0, 0, F::UnsupportedCodec),
            ("missing-plugin:video/mpegts", 0, 0, F::UnsupportedContainer),
            ("missing-plugin:video/quicktime", 0, 0, F::UnsupportedContainer),
            ("missing-plugin:video/x-matroska", 0, 0, F::UnsupportedContainer),
            ("missing-plugin:application/x-hls", 0, 0, F::UnsupportedContainer),
            ("missing-plugin:application/dash+xml", 0, 0, F::UnsupportedContainer),
            ("gst-stream-error-quark", 6, 0, F::UnsupportedCodec),
            ("gst-stream-error-quark", 4, 0, F::UnsupportedContainer),
            ("gst-stream-error-quark", 5, 0, F::UnsupportedContainer),
            ("gst-stream-error-quark", 9, 0, F::UnsupportedContainer),
            ("gst-stream-error-quark", 7, 0, F::DecodeError),
            ("gst-stream-error-quark", 1, net, F::Network),
            ("gst-stream-error-quark", 1, 0, F::DecodeError),
            ("gst-resource-error-quark", 3, 0, F::NotFound),
            ("gst-resource-error-quark", 3, net, F::NotFound),
            ("gst-resource-error-quark", 5, net, F::Network),
            ("gst-resource-error-quark", 5, 0, F::DecodeError),
        ];
        for (domain, code, underlying, want) in rows {
            assert_eq!(failure_reason(domain, *code, *underlying), *want, "{domain} {code} {underlying}");
        }
    }

    #[test]
    fn a_failure_report_carries_the_mapped_reason_and_the_platforms_sentence() {
        let (mut m, _, _) = with_source("http://127.0.0.1:1/h264_aac.mp4");
        let occs = m.report(
            P,
            Report::Failed {
                domain: "NSURLErrorDomain".into(),
                code: -1004,
                underlying: 0,
                detail: "Could not connect to the server.".into(),
            },
        );
        assert!(matches!(
            occs.as_slice(),
            [Occurrence::PlayerChanged {
                state: PlayerState::Failed,
                failure: Some(MediaFailure::Network),
                detail,
                ..
            }] if detail == "Could not connect to the server."
        ));
        // The first failure wins.
        assert!(m
            .report(P, Report::Failed { domain: "kaya".into(), code: 5, underlying: 0, detail: String::new() })
            .is_empty());
    }

    fn session(player: Option<PlayerId>, actions: u32) -> SessionSpec {
        SessionSpec { player, actions, ..SessionSpec::default() }
    }

    #[test]
    fn the_session_routes_an_action_to_the_app_first_then_the_attached_player() {
        let mut m = Media::default();
        m.create(P);
        let other = PlayerId(8);
        m.create(other);
        let mut out = Vec::new();
        m.set_session(session(Some(P), 0), &mut out);
        assert_eq!(m.route(SessionAction::Play), Route::Player(P, PlayerCommand::Play));
        assert_eq!(m.route(SessionAction::SeekTo(900)), Route::Player(P, PlayerCommand::Seek(900)));
        assert_eq!(m.route(SessionAction::Next), Route::NotOffered);
        assert_eq!(m.offered(), default_bits());
        // ONE OWNER: attaching another player moves every default to it.
        m.set_session(session(Some(other), 0), &mut out);
        assert_eq!(m.route(SessionAction::Pause), Route::Player(other, PlayerCommand::Pause));
        // The app's own handler wins over the default.
        m.set_session(session(Some(other), bit(SessionAction::Pause) | bit(SessionAction::Next)), &mut out);
        assert_eq!(m.route(SessionAction::Pause), Route::App);
        assert_eq!(m.route(SessionAction::Next), Route::App);
        assert_eq!(m.route(SessionAction::Play), Route::Player(other, PlayerCommand::Play));
    }

    #[test]
    fn releasing_the_attached_player_withdraws_its_defaults() {
        let mut m = Media::default();
        m.create(P);
        let mut out = Vec::new();
        m.set_session(session(Some(P), 0), &mut out);
        out.clear();
        m.release(P, &mut out);
        assert!(matches!(
            out.as_slice(),
            [ApplyOp::ReleasePlayer(_), ApplyOp::SetSession { player: None, offered: 0, .. }]
        ));
        assert_eq!(m.route(SessionAction::Play), Route::NotOffered);
        assert_eq!(m.system_state(), 0);
    }

    #[test]
    fn a_remote_play_after_the_end_replays() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        let mut out = Vec::new();
        m.set_session(session(Some(P), 0), &mut out);
        m.report(P, loaded(false));
        m.report(P, Report::Rate(true));
        assert_eq!(m.system_state(), 1);
        m.report(P, Report::Ended);
        assert_eq!(m.system_state(), 2);
        assert_eq!(m.route(SessionAction::Play), Route::Replay(P));
    }

    use crate::protocol::{
        CollectionId, PropValue, TemplateNodeId, TxOp, ValueType, WidgetId, WidgetKind, DEFAULT_WINDOW,
    };

    fn show(widget: u64, player: u64) -> TxOp {
        TxOp::SetProperty {
            widget: WidgetId(widget),
            prop: crate::protocol::Prop::Player,
            value: PropValue::Const(Value::I64(player as i64)),
        }
    }

    fn scene_with_video(kind: WidgetKind) -> (crate::scene::Scene, Vec<ApplyOp>) {
        let mut scene = crate::scene::Scene::new();
        let ops = scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind },
            TxOp::CreatePlayer { player: P },
            show(1, P.0),
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        (scene, ops)
    }

    #[test]
    fn a_video_view_shows_a_live_player() {
        let (_, ops) = scene_with_video(WidgetKind::Video);
        assert!(ops.contains(&ApplyOp::SetVideoPlayer { widget: WidgetId(1), player: Some(P) }));
    }

    #[test]
    #[should_panic(expected = "Player")]
    fn only_a_video_view_shows_a_player() {
        scene_with_video(WidgetKind::Label);
    }

    /// A column of rows, each a video view bound to the row's player field
    /// (docs/media-plan.md §7b).
    fn feed(players: &[u64]) -> (crate::scene::Scene, Vec<ApplyOp>) {
        let mut scene = crate::scene::Scene::new();
        let mut tx = vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::I64]] },
            TxOp::CreateFor { id: 2, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Video },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: crate::protocol::Prop::Player,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::TemplateEnd,
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ];
        let mut made = std::collections::HashSet::new();
        for p in players {
            if *p != 0 && made.insert(*p) {
                tx.push(TxOp::CreatePlayer { player: PlayerId(*p) });
            }
        }
        for (i, p) in players.iter().enumerate() {
            tx.push(row(i as i64, *p, false));
        }
        let ops = scene.apply(tx);
        (scene, ops)
    }

    fn row(key: i64, player: u64, update: bool) -> TxOp {
        let (id, path, key, variant, record) =
            (CollectionId(1), vec![], Value::I64(key), 0, vec![Value::I64(player as i64)]);
        if update {
            TxOp::CollectionUpdate { id, path, key, variant, record }
        } else {
            TxOp::CollectionInsert { id, path, key, variant, record }
        }
    }

    fn shown(ops: &[ApplyOp]) -> Vec<Option<PlayerId>> {
        ops.iter()
            .filter_map(|op| match op {
                ApplyOp::SetVideoPlayer { player, .. } => Some(*player),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn each_row_shows_its_own_player() {
        let (_, ops) = feed(&[3, 4, 0]);
        assert_eq!(shown(&ops), [Some(PlayerId(3)), Some(PlayerId(4)), None]);
    }

    #[test]
    #[should_panic(expected = "player 3 is shown by the video view stamped from template node 10 at keys [I64(0)] and by the video view stamped from template node 10 at keys [I64(1)]")]
    fn two_rows_showing_one_player_are_refused_naming_both() {
        feed(&[3, 3]);
    }

    #[test]
    #[should_panic(expected = "player 7 is shown by video view 1 and by video view 2")]
    fn two_live_views_showing_one_player_are_refused_naming_both() {
        let mut scene = crate::scene::Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Video },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Video },
            TxOp::AddChild { parent: WidgetId(3), child: WidgetId(1) },
            TxOp::AddChild { parent: WidgetId(3), child: WidgetId(2) },
            TxOp::CreatePlayer { player: P },
            show(1, P.0),
            show(2, P.0),
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(3) },
        ]);
    }

    /// The rule holds on the batch's END state: two rows trading players in
    /// one transaction is one move, whichever row is written first.
    #[test]
    fn rows_trading_players_in_one_transaction_is_not_a_second_view() {
        let (mut scene, _) = feed(&[3, 4]);
        let ops = scene.apply(vec![row(0, 4, true), row(1, 3, true)]);
        assert_eq!(shown(&ops), [Some(PlayerId(4)), Some(PlayerId(3))]);
        // A view that went away frees its player for another.
        let ops = scene.apply(vec![
            TxOp::CollectionRemove { id: CollectionId(1), path: vec![], key: Value::I64(0) },
            row(1, 4, true),
        ]);
        assert_eq!(shown(&ops), [Some(PlayerId(4))]);
    }

    #[test]
    fn a_row_naming_a_released_player_shows_none() {
        let (mut scene, _) = feed(&[3]);
        scene.apply(vec![TxOp::ReleasePlayer { player: PlayerId(3) }]);
        let ops = scene.apply(vec![row(0, 3, true)]);
        assert_eq!(shown(&ops), [None]);
    }

    #[test]
    #[should_panic(expected = "shows player 9, which was never created")]
    fn a_row_naming_a_player_never_created_is_refused() {
        let (mut scene, _) = feed(&[3]);
        scene.apply(vec![row(0, 9, true)]);
    }

    #[test]
    fn visibility_is_coalesced_to_entering_leaving_tenths_and_whole() {
        let mut v = Visibility::default();
        let w = WidgetId(5);
        assert_eq!(v.report(w, 0.0), None, "never shown: leaving is not news");
        assert_eq!(v.report(w, 0.01), Some(0.01), "entering");
        assert_eq!(v.report(w, 0.05), None, "the same tenth, a frame of a scroll later");
        assert_eq!(v.report(w, 0.09), None);
        assert_eq!(v.report(w, 0.12), Some(0.12));
        assert_eq!(v.report(w, 0.55), Some(0.55));
        assert_eq!(v.report(w, 0.991), Some(0.991));
        assert_eq!(v.report(w, 0.9995), Some(0.9995), "whole");
        assert_eq!(v.report(w, 1.0), None);
        assert_eq!(v.report(w, 0.0), Some(0.0), "leaving");
        assert_eq!(v.report(w, f64::NAN), None, "an unmeasurable report reads as not shown");
        assert!(!v.gone(w), "a view not shown leaves nothing to say");
        v.report(w, 0.3);
        assert!(v.gone(w));
    }

    /// A scroll's sixty frames reach the app as the handful of bands they
    /// crossed, addressed to the copy by its keys.
    #[test]
    fn a_scroll_through_a_stamped_view_is_heard_by_its_keys_a_few_times() {
        let (mut scene, ops) = feed(&[3]);
        let copy = ops
            .iter()
            .find_map(|op| match op {
                ApplyOp::SetVideoPlayer { widget, .. } => Some(*widget),
                _ => None,
            })
            .unwrap();
        let mut heard = Vec::new();
        for frame in 0..=60 {
            heard.extend(scene.video_visible(copy, frame as f64 / 60.0).0);
        }
        assert_eq!(heard.len(), 11, "entering, nine tenths and whole: {heard:?}");
        assert!(heard.iter().all(|o| matches!(o,
            Occurrence::InstanceVideoVisibility { node: TemplateNodeId(10), path, .. } if path == &[Value::I64(0)])));
        // The copy torn down while shown: the app hears it leave.
        scene.apply(vec![TxOp::CollectionRemove { id: CollectionId(1), path: vec![], key: Value::I64(0) }]);
        assert!(matches!(
            scene.take_asks().as_slice(),
            [Occurrence::InstanceVideoVisibility { shown, .. }] if *shown == 0.0
        ));
        assert!(scene.video_visible(copy, 1.0).0.is_empty(), "a torn-down copy reports nothing");
    }

    fn source(player: u64, url: &str) -> TxOp {
        TxOp::SetPlayerProp {
            player: PlayerId(player),
            prop: PlayerProp::Source,
            value: Value::Str(url.into()),
        }
    }

    const CLIP: &str = "media/h264_aac.mp4";

    /// The source ops `ops` hand the platform, per player: "" for a close.
    fn sources(ops: &[ApplyOp]) -> Vec<(u64, bool)> {
        ops.iter()
            .filter_map(|op| match op {
                ApplyOp::SetPlayerProp { player, prop: PlayerProp::Source, value: Value::Str(url) } => {
                    Some((player.0, !url.is_empty()))
                }
                _ => None,
            })
            .collect()
    }

    /// A feed whose players were sourced in the transaction that inserted
    /// their rows, as media_feed's guests do, and each row's copy.
    fn sourced_feed(players: &[u64]) -> (crate::scene::Scene, Vec<ApplyOp>, Vec<WidgetId>) {
        let (mut scene, mut ops) = feed(&[]);
        let mut tx = Vec::new();
        for (i, p) in players.iter().enumerate() {
            tx.push(TxOp::CreatePlayer { player: PlayerId(*p) });
            tx.push(source(*p, CLIP));
            tx.push(row(i as i64, *p, false));
        }
        ops.extend(scene.apply(tx));
        let copies = ops
            .iter()
            .filter_map(|op| match op {
                ApplyOp::SetVideoPlayer { widget, .. } => Some(*widget),
                _ => None,
            })
            .collect();
        (scene, ops, copies)
    }

    /// THE LAZY OPEN (docs/media-plan.md §7d): a row's player hands its
    /// source to the platform when its view first shows, and not before.
    #[test]
    fn a_rows_player_opens_only_once_its_view_shows() {
        let (mut scene, ops, copies) = sourced_feed(&[3, 4]);
        assert_eq!(sources(&ops), [], "no row's view has shown yet");
        assert!(scene.player_held(PlayerId(3)) && scene.player_held(PlayerId(4)));
        assert_eq!(sources(&scene.video_visible(copies[1], 0.0).1), []);
        let (_, opened) = scene.video_visible(copies[0], 0.05);
        assert_eq!(sources(&opened), [(3, true)]);
        assert!(!scene.player_held(PlayerId(3)) && scene.player_held(PlayerId(4)));
        assert_eq!(sources(&scene.video_visible(copies[0], 1.0).1), [], "handed over once");
        assert_eq!(sources(&scene.video_visible(copies[1], 1.0).1), [(4, true)]);
    }

    /// A player no row names opens at once: audio alone, or a live view.
    #[test]
    fn a_player_no_row_names_opens_at_once() {
        let (mut scene, _) = scene_with_video(WidgetKind::Video);
        let ops = scene.apply(vec![source(P.0, CLIP), TxOp::CreatePlayer { player: PlayerId(8) }, source(8, CLIP)]);
        assert_eq!(sources(&ops), [(P.0, true), (8, true)]);
    }

    /// Every op for a held player waits behind its source and keeps its order.
    #[test]
    fn a_held_players_commands_follow_its_source_at_the_hand_over() {
        let (mut scene, _, copies) = sourced_feed(&[3]);
        let ops = scene.apply(vec![
            TxOp::PlayerCommand { player: PlayerId(3), command: PlayerCommand::Seek(500) },
            TxOp::PlayerCommand { player: PlayerId(3), command: PlayerCommand::Play },
        ]);
        assert!(!ops.iter().any(|op| matches!(op, ApplyOp::PlayerCommand { .. })), "{ops:?}");
        let (_, opened) = scene.video_visible(copies[0], 1.0);
        let order: Vec<&str> = opened
            .iter()
            .filter_map(|op| match op {
                ApplyOp::SetPlayerProp { prop: PlayerProp::Source, .. } => Some("source"),
                ApplyOp::PlayerCommand { command: PlayerCommand::Seek(_), .. } => Some("seek"),
                ApplyOp::PlayerCommand { command: PlayerCommand::Play, .. } => Some("play"),
                _ => None,
            })
            .collect();
        assert_eq!(order, ["source", "seek", "play"]);
    }

    /// A new source on an open player whose row is out of view closes the
    /// platform's item and holds the new one; a shown row's opens at once.
    #[test]
    fn a_new_source_off_screen_closes_the_item_and_waits() {
        let (mut scene, _, copies) = sourced_feed(&[3]);
        scene.video_visible(copies[0], 1.0);
        assert_eq!(sources(&scene.apply(vec![source(3, "media/tone.mp3")])), [(3, true)], "still shown");
        scene.video_visible(copies[0], 0.0);
        assert_eq!(sources(&scene.apply(vec![source(3, CLIP)])), [(3, false)]);
        assert!(scene.player_held(PlayerId(3)));
        assert_eq!(sources(&scene.video_visible(copies[0], 0.5).1), [(3, true)]);
    }

    /// The app clearing a held player's source, or releasing it, ends the
    /// hold with nothing handed over.
    #[test]
    fn clearing_or_releasing_a_held_player_ends_the_hold() {
        let (mut scene, _, copies) = sourced_feed(&[3, 4]);
        let ops = scene.apply(vec![source(3, ""), TxOp::ReleasePlayer { player: PlayerId(4) }]);
        assert_eq!(sources(&ops), [(3, false)]);
        assert!(!scene.player_held(PlayerId(3)) && !scene.player_held(PlayerId(4)));
        assert_eq!(sources(&scene.video_visible(copies[0], 1.0).1), []);
    }

    /// A row the band has not realized has no view, and its player still
    /// waits: the row names it. A player whose row went away is no row's.
    #[test]
    fn a_player_in_a_row_with_no_view_waits() {
        let (mut scene, _, _) = sourced_feed(&[30, 31, 32, 33, 34, 35, 36, 37, 38, 39]);
        scene.declare_windowing();
        let band = scene.window_moved(2, 0, 1);
        assert!(band.iter().any(|op| matches!(op, ApplyOp::Destroy { .. })), "the band tore rows down: {band:?}");
        let ops = scene.apply(vec![
            TxOp::CreatePlayer { player: PlayerId(20) },
            source(20, CLIP),
            row(9, 20, true),
        ]);
        assert!(!ops.iter().any(|op| matches!(op, ApplyOp::SetVideoPlayer { .. })), "row 9 is unrealized: {ops:?}");
        assert_eq!(sources(&ops), [(39, true)], "39 left every row, so it opens; 20 waits");
        assert!(scene.player_held(PlayerId(20)));
        let ops = scene.apply(vec![TxOp::CreatePlayer { player: PlayerId(6) }, source(6, CLIP)]);
        assert_eq!(sources(&ops), [(6, true)]);
    }

    const VTT: &str = "WEBVTT\n\n00:00.000 --> 00:01.000\nfirst cue\n\n00:01.000 --> 00:02.000\nsecond cue\n";

    #[test]
    fn an_http_sidecar_is_fetched_by_the_backend_and_parsed_here() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        let (mut out, mut heard) = (Vec::new(), Vec::new());
        let url = "http://127.0.0.1:8765/captions.vtt";
        m.set_prop(P, PlayerProp::Captions, Value::Str(url.into()), &mut out, &mut heard);
        assert!(
            out.contains(&ApplyOp::SetPlayerProp { player: P, prop: PlayerProp::Captions, value: Value::Str(url.into()) }),
            "the backend is handed the URL to fetch: {out:?}"
        );
        assert!(m.report(P, Report::CaptionsText { url: "http://elsewhere/old.vtt".into(), text: VTT.into() }).is_empty());
        let heard = m.report(P, Report::CaptionsText { url: url.into(), text: VTT.into() });
        assert!(
            heard.iter().any(|o| matches!(o, Occurrence::PlayerTracks { tracks, .. } if tracks.captions == ["und"])),
            "the fetched sidecar is listed: {heard:?}"
        );
        let (mut out, mut heard) = (Vec::new(), Vec::new());
        m.select(P, TrackKind::Caption, 1, &mut out, &mut heard);
        assert_eq!(m.caption_at(P, 1500).0, "second cue");
    }

    #[test]
    fn a_failed_sidecar_fetch_fails_the_player_with_the_mapped_reason() {
        for (code, want) in [(404, MediaFailure::NotFound), (503, MediaFailure::Network)] {
            let (mut m, _, _) = with_source("media/h264_aac.mp4");
            let (mut out, mut heard) = (Vec::new(), Vec::new());
            let url = "http://127.0.0.1:8765/nope.vtt";
            m.set_prop(P, PlayerProp::Captions, Value::Str(url.into()), &mut out, &mut heard);
            let heard = m.report(
                P,
                Report::CaptionsFailed { url: url.into(), domain: "http".into(), code, underlying: 0, detail: String::new() },
            );
            assert!(
                heard.iter().any(|o| matches!(o, Occurrence::PlayerChanged { state: PlayerState::Failed, failure: Some(f), .. } if *f == want)),
                "{code}: {heard:?}"
            );
        }
    }

    #[test]
    fn replacing_a_pending_fetch_with_a_local_sidecar_cancels_it() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        let (mut out, mut heard) = (Vec::new(), Vec::new());
        let url = "https://example.invalid/c.vtt";
        m.set_prop(P, PlayerProp::Captions, Value::Str(url.into()), &mut out, &mut heard);
        out.clear();
        m.set_prop(P, PlayerProp::Captions, Value::Str("media/captions.vtt".into()), &mut out, &mut heard);
        assert!(out.contains(&ApplyOp::SetPlayerProp { player: P, prop: PlayerProp::Captions, value: Value::Str(String::new()) }));
        let late = m.report(
            P,
            Report::CaptionsFailed { url: url.into(), domain: "http".into(), code: 404, underlying: 0, detail: String::new() },
        );
        assert!(late.is_empty(), "a stale fetch's answer is not news: {late:?}");
    }

    #[cfg(feature = "harness")]
    #[test]
    fn caption_snapshot_measures_without_publishing() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        assert!(m.caption_snapshot(PlayerId(999), Some(1500)).is_none());
        let absent = m.caption_snapshot(P, Some(1500)).unwrap();
        assert!(!absent.sidecar && !absent.selected && absent.boundaries.is_empty());
        assert_eq!(absent.sidecar_expected, Some(String::new()));
        let mut out = Vec::new();
        let mut heard = Vec::new();
        m.set_prop(P, PlayerProp::Captions, Value::Str("media/captions.vtt".into()), &mut out, &mut heard);
        let off = m.caption_snapshot(P, Some(1500)).unwrap();
        assert!(off.sidecar && !off.selected);
        assert_eq!(off.sidecar_expected, Some(String::new()));
        m.select(P, TrackKind::Caption, 1, &mut out, &mut heard);
        let before = m.caption_snapshot(P, Some(500)).unwrap();
        assert_eq!(before.boundaries, vec![0, 1000, 2000]);
        assert_eq!(before.sidecar_expected.as_deref(), Some("first cue"));
        for (at, expected) in [(Some(1500), Some("second cue")), (Some(2000), Some("")), (None, None)] {
            let snapshot = m.caption_snapshot(P, at).unwrap();
            assert_eq!(snapshot.sidecar_expected.as_deref(), expected);
            assert_eq!(snapshot.published, before.published);
            assert_eq!(snapshot.state, before.state);
            assert_eq!(snapshot.duration_ms, before.duration_ms);
            eprintln!("caption snapshot at={at:?}: {snapshot:?}");
        }
        assert_eq!(m.caption_snapshot(P, Some(500)).unwrap(), before);
        assert_eq!(m.caption_at(P, 1500).1,
            vec![Occurrence::CaptionCue { player: P, text: "second cue".into() }]);
        assert!(m.caption_at(P, 1500).1.is_empty());
    }

    #[test]
    fn a_sidecar_is_the_last_caption_track_and_the_core_times_its_cues() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        let mut out = Vec::new();
        let mut heard = Vec::new();
        m.set_prop(P, PlayerProp::CaptionsLanguage, Value::Str("en".into()), &mut out, &mut heard);
        m.set_prop(P, PlayerProp::Captions, Value::Str("media/captions.vtt".into()), &mut out, &mut heard);
        heard.clear();
        heard.extend(m.report(
            P,
            Report::Tracks {
                audio: vec!["en".into(), "fr".into()],
                captions: vec!["fr".into()],
                audio_selected: Some(0),
                caption_selected: None,
            },
        ));
        let tracks = |occs: &[Occurrence]| {
            occs.iter()
                .filter_map(|o| match o {
                    Occurrence::PlayerTracks { tracks, .. } => Some(tracks.clone()),
                    _ => None,
                })
                .last()
        };
        let listing = tracks(&heard).unwrap();
        assert_eq!(listing.captions, ["fr", "en"]);
        assert_eq!((listing.audio_selected, listing.caption_selected), (Some(0), None));
        // Nothing selected: kaya times nothing.
        assert_eq!(m.caption_at(P, 500).0, "");
        out.clear();
        heard.clear();
        m.select(P, TrackKind::Caption, 2, &mut out, &mut heard);
        assert_eq!(
            out,
            [
                ApplyOp::SelectTrack { player: P, kind: TrackKind::Caption, index: 0 },
                ApplyOp::CaptionTimes { player: P, times: vec![0, 1000, 2000] },
            ]
        );
        assert_eq!(tracks(&heard).unwrap().caption_selected, Some(1));
        let (text, occs) = m.caption_at(P, 500);
        assert_eq!(text, "first cue");
        assert_eq!(occs, [Occurrence::CaptionCue { player: P, text: "first cue".into() }]);
        assert!(m.caption_at(P, 700).1.is_empty(), "the same cue is not news");
        assert_eq!(m.caption_at(P, 1500).1, [Occurrence::CaptionCue { player: P, text: "second cue".into() }]);
        // While kaya draws, the platform's own cue is not the app's news.
        assert!(m.report(P, Report::Cue("platform".into())).is_empty());
        // The platform's track instead: kaya stops timing, and says so.
        out.clear();
        heard.clear();
        m.select(P, TrackKind::Caption, 1, &mut out, &mut heard);
        assert_eq!(
            out,
            [
                ApplyOp::SelectTrack { player: P, kind: TrackKind::Caption, index: 1 },
                ApplyOp::CaptionTimes { player: P, times: vec![] },
            ]
        );
        assert!(heard.contains(&Occurrence::CaptionCue { player: P, text: String::new() }));
        assert_eq!(m.report(P, Report::Cue("first cue".into())), [Occurrence::CaptionCue {
            player: P,
            text: "first cue".into()
        }]);
    }

    #[test]
    #[should_panic(expected = "caption track 3 of player 7, whose caption tracks are []")]
    fn a_caption_track_past_the_listing_is_refused() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.select(P, TrackKind::Caption, 3, &mut Vec::new(), &mut Vec::new());
    }

    #[test]
    fn running_out_of_decoders_is_resources() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        let occs = m.report(
            P,
            Report::Failed {
                domain: "AVFoundationErrorDomain".into(),
                code: -11839,
                underlying: 0,
                detail: "The decoder required for this media is busy.".into(),
            },
        );
        assert!(matches!(occs.as_slice(), [Occurrence::PlayerChanged { failure: Some(MediaFailure::Resources), .. }]));
    }

    fn failed(domain: &str, code: i64, underlying: i64) -> Report {
        Report::Failed { domain: domain.into(), code, underlying, detail: String::new() }
    }

    fn failure(occs: &[Occurrence]) -> Option<MediaFailure> {
        occs.iter().find_map(|o| match o {
            Occurrence::PlayerChanged { state: PlayerState::Failed, failure, .. } => *failure,
            _ => None,
        })
    }

    /// Q opened first and is in `others`' state, then P loads.
    fn two_players(other: PlayerState) -> Media {
        const Q: PlayerId = PlayerId(8);
        let (mut m, mut out, mut heard) = (Media::default(), Vec::new(), Vec::new());
        m.create(Q);
        m.create(P);
        if other != PlayerState::Idle {
            m.set_prop(Q, PlayerProp::Source, Value::Str("media/h264_aac.mp4".into()), &mut out, &mut heard);
        }
        match other {
            PlayerState::Ready => drop(m.report(Q, loaded(false))),
            PlayerState::Playing => {
                m.report(Q, loaded(false));
                m.report(Q, Report::Rate(true));
            }
            PlayerState::Failed => drop(m.report(Q, failed("media3", 2005, 0))),
            _ => {}
        }
        assert_eq!(m.state(Q), Some(other));
        m.set_prop(P, PlayerProp::Source, Value::Str("media/h264_aac.mp4".into()), &mut out, &mut heard);
        m
    }

    /// The ruling of 2026-09-30, measured on the emulator pool: the 15th
    /// player's decoder fails 4003 over CodecException 14 (H.264, HEVC) or
    /// -19 (AV1) while fourteen play.
    #[test]
    fn a_decoder_that_never_started_while_other_players_are_open_is_resources() {
        for (code, underlying) in [(4003, 14), (4003, -19), (4001, 0)] {
            for other in [PlayerState::Loading, PlayerState::Ready, PlayerState::Playing] {
                let mut m = two_players(other);
                let heard = m.report(P, failed("media3", code, underlying));
                assert_eq!(failure(&heard), Some(MediaFailure::Resources), "{code} over {underlying}, the other {other:?}");
            }
        }
    }

    #[test]
    fn the_same_failure_alone_or_after_the_start_is_a_decode_error() {
        for other in [PlayerState::Idle, PlayerState::Failed] {
            let mut m = two_players(other);
            assert_eq!(failure(&m.report(P, failed("media3", 4003, 14))), Some(MediaFailure::DecodeError), "{other:?}");
        }
        let mut m = two_players(PlayerState::Playing);
        m.report(P, loaded(false));
        assert_eq!(failure(&m.report(P, failed("media3", 4003, 14))), Some(MediaFailure::DecodeError));
        let mut m = two_players(PlayerState::Playing);
        assert_eq!(
            failure(&m.report(P, failed("AVFoundationErrorDomain", -11821, 0))),
            Some(MediaFailure::DecodeError)
        );
        let mut m = two_players(PlayerState::Playing);
        assert_eq!(failure(&m.report(P, failed("media3", 3001, 0))), Some(MediaFailure::DecodeError));
    }

    /// A picked file the platform names only by its own reference.
    struct Reference {
        locator: String,
        bytes: std::path::PathBuf,
    }

    impl crate::protocol::PickedSource for Reference {
        fn open(&self, _: crate::protocol::FileMode) -> std::io::Result<(i64, bool)> {
            Ok((crate::protocol::raw_handle(std::fs::File::open(&self.bytes)?), true))
        }
        fn name(&self) -> &str {
            "clip"
        }
        fn local_path(&self) -> &str {
            ""
        }
        fn locator(&self) -> &str {
            &self.locator
        }
    }

    fn handed(out: &[ApplyOp], prop: PlayerProp) -> Vec<String> {
        out.iter()
            .filter_map(|op| match op {
                ApplyOp::SetPlayerProp { prop: p, value: Value::Str(s), .. } if *p == prop => Some(s.clone()),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_picked_file_with_only_the_platforms_reference_is_handed_over_as_that_reference() {
        let uri = "content://com.android.externalstorage.documents/document/primary%3ADocuments%2Fclip.mp4";
        let handle = crate::capi::picked_register(std::sync::Arc::new(Reference {
            locator: uri.into(),
            bytes: std::path::PathBuf::from("/nonexistent"),
        }));
        let (mut m, mut out, mut heard) = (Media::default(), Vec::new(), Vec::new());
        m.create(P);
        m.set_prop(P, PlayerProp::Source, Value::I64(handle.0 as i64), &mut out, &mut heard);
        assert_eq!(handed(&out, PlayerProp::Source), [uri]);
        assert_eq!(states(&heard), [PlayerState::Loading]);
    }

    #[test]
    fn a_picked_path_is_checked_and_handed_over_like_any_path() {
        let dir = std::env::temp_dir().join(format!("kaya-media-picked-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let clip = dir.join("clip.mp4");
        std::fs::write(&clip, b"not really").unwrap();
        let path = |p: &std::path::Path| {
            crate::capi::picked_register(std::sync::Arc::new(crate::protocol::PathSource {
                name: "clip.mp4".into(),
                path: p.to_string_lossy().into_owned(),
            }))
        };
        let (here, gone) = (path(&clip), path(&dir.join("gone.mp4")));
        let (mut m, mut out, mut heard) = (Media::default(), Vec::new(), Vec::new());
        m.create(P);
        m.set_prop(P, PlayerProp::Source, Value::I64(here.0 as i64), &mut out, &mut heard);
        assert_eq!(handed(&out, PlayerProp::Source), [crate::assets::file_url(&clip)]);
        out.clear();
        heard.clear();
        m.set_prop(P, PlayerProp::Source, Value::I64(gone.0 as i64), &mut out, &mut heard);
        assert_eq!(failure(&heard), Some(MediaFailure::NotFound));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_picked_sidecar_is_read_through_its_own_open() {
        let dir = std::env::temp_dir().join(format!("kaya-media-picked-vtt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("c.vtt"), VTT).unwrap();
        let handle = crate::capi::picked_register(std::sync::Arc::new(Reference {
            locator: "content://provider/c.vtt".into(),
            bytes: dir.join("c.vtt"),
        }));
        let (mut m, mut out, mut heard) = with_source("media/h264_aac.mp4");
        m.set_prop(P, PlayerProp::Captions, Value::I64(handle.0 as i64), &mut out, &mut heard);
        assert!(handed(&out, PlayerProp::Captions).is_empty(), "nothing to fetch: {out:?}");
        m.select(P, TrackKind::Caption, 1, &mut out, &mut heard);
        assert_eq!(m.caption_at(P, 1500).0, "second cue");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    #[should_panic(expected = "names picked file 999999, which was never minted")]
    fn a_picked_handle_never_minted_is_refused() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.set_prop(P, PlayerProp::Source, Value::I64(999_999), &mut Vec::new(), &mut Vec::new());
    }

    #[test]
    #[should_panic(expected = "not live")]
    fn a_session_cannot_attach_a_player_that_is_not_live() {
        Media::default().set_session(session(Some(P), 0), &mut Vec::new());
    }
}

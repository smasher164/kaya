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

/// How long a source may stay `loading` before the core calls it failed: a
/// pipeline missing an element stalls without a word (docs/media-plan.md
/// §7a), 20 s being the probe's own hang window.
pub(crate) const LOADING_CEILING_MS: u64 = 20_000;

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
    /// LOADING_CEILING_MS passed since the source was handed over.
    Overdue,
    /// The platform's own tracks: language tags in its order, and which of
    /// each list it has selected.
    Tracks { audio: Vec<String>, captions: Vec<String>, audio_selected: Option<usize>, caption_selected: Option<usize> },
    /// The text the platform shows for its own selected caption track now.
    Cue(String),
}

#[derive(Debug, Clone, PartialEq)]
struct Player {
    state: PlayerState,
    failure: Option<MediaFailure>,
    detail: String,
    duration_ms: u64,
    size: (u32, u32),
    looping: bool,
    remote: bool,
    /// A `playing` report that beat the item's own `loaded` one.
    early_rate: bool,
    /// Seeks the APP asked for and the platform has not yet landed; a seek
    /// the core issued itself (a replay after `ended`) is not the app's.
    seeks: u32,
    /// The platform's own tracks, as it last reported them.
    platform: PlayerTracks,
    /// A sidecar WebVTT file, kaya's to draw, and whether it is selected.
    sidecar: Option<Captions>,
    sidecar_language: String,
    sidecar_selected: bool,
    /// What the app last heard: the listing, and the current cue.
    published_tracks: PlayerTracks,
    cue: String,
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
            remote: false,
            early_rate: false,
            seeks: 0,
            platform: PlayerTracks::default(),
            sidecar: None,
            sidecar_language: "und".to_owned(),
            sidecar_selected: false,
            published_tracks: PlayerTracks::default(),
            cue: String::new(),
        }
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
    Url { url: String, remote: bool },
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
}

impl Media {
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
        let p = self.live_mut(player, "set_player_prop");
        match (prop, value) {
            (PlayerProp::Source, Value::Str(source)) => {
                let resolved = resolve_source(&source);
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
                p.platform = PlayerTracks::default();
                match resolved {
                    Resolved::None => p.state = PlayerState::Idle,
                    Resolved::Url { remote, .. } => {
                        p.state = PlayerState::Loading;
                        p.remote = remote;
                    }
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
            (PlayerProp::Captions, Value::Str(source)) => {
                p.sidecar = if source.is_empty() { None } else { Some(read_sidecar(player, &source)) };
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
                "kaya: player {} {prop:?} got {value:?} — source, captions and captions_language \
                 are Str, speed and volume F64, muted and loop Bool (spec::PLAYER_PROPS)",
                player.0
            ),
        }
    }

    pub(crate) fn command(&mut self, player: PlayerId, command: PlayerCommand, out: &mut Vec<ApplyOp>) {
        let p = self.live_mut(player, "player_command");
        match command {
            PlayerCommand::Play if p.state == PlayerState::Ended => {
                out.push(ApplyOp::PlayerCommand { player, command: PlayerCommand::Seek(0) });
            }
            PlayerCommand::Seek(_) => p.seeks += 1,
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
        let Some(p) = self.players.get_mut(&player) else {
            return Vec::new();
        };
        use PlayerState as S;
        let mut out = Vec::new();
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
                p.state = S::Failed;
                p.failure = Some(failure_reason(&domain, code, underlying));
                p.detail = if detail.is_empty() { format!("{domain} {code}") } else { detail };
                out.push(changed(player, p));
            }
            (S::Loading, Report::Overdue) => {
                p.state = S::Failed;
                p.failure = Some(if p.remote { MediaFailure::Network } else { MediaFailure::UnsupportedContainer });
                p.detail = format!(
                    "kaya: still loading after {LOADING_CEILING_MS} ms and the platform reported nothing"
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
        _ => F::DecodeError,
    }
}

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
        return Resolved::Url { url: source.to_owned(), remote: true };
    }
    if let Some(refusal) = refused_before_load(&lower) {
        return refusal;
    }
    if source.starts_with('/') {
        return if std::path::Path::new(source).is_file() {
            Resolved::Url { url: crate::assets::file_url(std::path::Path::new(source)), remote: false }
        } else {
            Resolved::Refused(MediaFailure::NotFound, format!("kaya: no file at {source}"))
        };
    }
    match crate::assets::media_locator(source) {
        Ok(url) => Resolved::Url { url, remote: false },
        Err(why) => Resolved::Refused(MediaFailure::NotFound, why),
    }
}

/// A sidecar WebVTT file, read and parsed by the core (docs/media-plan.md
/// §3): an asset name or a picked file's absolute path. kaya has no HTTP
/// client, so a stream's captions ride inside the stream (HLS) instead.
fn read_sidecar(player: PlayerId, source: &str) -> Captions {
    let lower = source.to_ascii_lowercase();
    assert!(
        !(lower.starts_with("http://") || lower.starts_with("https://")),
        "kaya: player {} captions {source:?} — a sidecar caption file is a local source, an asset \
         name or a picked file's path; a stream carries its captions inside it (docs/media-plan.md §3)",
        player.0
    );
    let bytes = if source.starts_with('/') {
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

#[cfg(test)]
mod tests {
    use super::*;

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
            Resolved::Url { url: "https://example.invalid/a.m3u8".into(), remote: true }
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

    #[test]
    fn a_stall_past_the_ceiling_fails_by_where_the_source_lives() {
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        assert!(matches!(
            m.report(P, Report::Overdue).as_slice(),
            [Occurrence::PlayerChanged { failure: Some(MediaFailure::UnsupportedContainer), .. }]
        ));
        let (mut m, _, _) = with_source("http://127.0.0.1:8765/hls_mpegts.m3u8");
        assert!(matches!(
            m.report(P, Report::Overdue).as_slice(),
            [Occurrence::PlayerChanged { failure: Some(MediaFailure::Network), .. }]
        ));
        // A player that readied is past the ceiling's reach.
        let (mut m, _, _) = with_source("media/h264_aac.mp4");
        m.report(P, loaded(false));
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
            heard.extend(scene.video_visible(copy, frame as f64 / 60.0));
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
        assert!(scene.video_visible(copy, 1.0).is_empty(), "a torn-down copy reports nothing");
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
    #[should_panic(expected = "a sidecar caption file is a local source")]
    fn a_streamed_sidecar_is_refused() {
        let (mut m, mut out, mut heard) = with_source("media/h264_aac.mp4");
        m.set_prop(P, PlayerProp::Captions, Value::Str("http://127.0.0.1/c.vtt".into()), &mut out, &mut heard);
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

    #[test]
    #[should_panic(expected = "not live")]
    fn a_session_cannot_attach_a_player_that_is_not_live() {
        Media::default().set_session(session(Some(P), 0), &mut Vec::new());
    }
}

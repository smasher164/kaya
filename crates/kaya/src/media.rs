//! Media: the player's state machine, the failure table, the source's
//! resolution and the session's one-owner rule (docs/media-plan.md §2, §5,
//! §7a). A backend reports what its platform said; this decides what the
//! app hears, so the nine bindings and five platforms read one machine.

use std::collections::HashMap;

use crate::protocol::{
    ApplyOp, MediaFailure, Occurrence, PlaybackState, PlayerCommand, PlayerId, PlayerProp, PlayerState,
    SessionAction, SessionSpec, Value,
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
        }
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
                out.push(ApplyOp::SetPlayerProp { player, prop, value: Value::Str(url) });
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
                "kaya: player {} {prop:?} got {value:?} — source is a Str, speed and volume \
                 F64, muted and loop Bool (spec::PLAYER_PROPS)",
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

    pub(crate) fn release(&mut self, player: PlayerId, out: &mut Vec<ApplyOp>) {
        assert!(
            self.players.remove(&player).is_some(),
            "kaya: release_player names player {}, which is not live",
            player.0
        );
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

    fn scene_with_video(kind: crate::protocol::WidgetKind) -> (crate::scene::Scene, Vec<ApplyOp>) {
        use crate::protocol::{TxOp, WidgetId};
        let mut scene = crate::scene::Scene::new();
        let ops = scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind },
            TxOp::CreatePlayer { player: P },
            TxOp::SetVideoPlayer { widget: WidgetId(1), player: Some(P) },
            TxOp::Mount { window: crate::protocol::DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        (scene, ops)
    }

    #[test]
    fn a_video_view_shows_a_live_player() {
        let (_, ops) = scene_with_video(crate::protocol::WidgetKind::Video);
        assert!(ops.contains(&ApplyOp::SetVideoPlayer {
            widget: crate::protocol::WidgetId(1),
            player: Some(P),
        }));
    }

    #[test]
    #[should_panic(expected = "not a live video view")]
    fn only_a_video_view_shows_a_player() {
        scene_with_video(crate::protocol::WidgetKind::Label);
    }

    #[test]
    #[should_panic(expected = "not live")]
    fn a_session_cannot_attach_a_player_that_is_not_live() {
        Media::default().set_session(session(Some(P), 0), &mut Vec::new());
    }
}

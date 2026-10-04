//! Media on WinUI (docs/media-plan.md, the WinUI rows): a
//! `Windows.Media.Playback.MediaPlayer` per player, the video view a
//! `MediaPlayerElement` with its transport controls off, the session the
//! attached player's own SMTC. Every platform fact goes to the core's one
//! state machine through `report`; the core decides what the app hears.

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use windows_core::{Interface as _, HSTRING};

use super::bindings::Microsoft::UI::Dispatching::{DispatcherQueueHandler, DispatcherQueueTimer};
use super::bindings::Microsoft::UI::Xaml::Controls::{Grid, MediaPlayerElement, TextBlock};
use super::bindings::Microsoft::UI::Xaml::Media::{SolidColorBrush, Stretch, VisualTreeHelper};
use super::bindings::Microsoft::UI::Xaml::{
    FrameworkElement, HorizontalAlignment, TextWrapping, Thickness, UIElement, VerticalAlignment, Visibility,
};
use super::bindings::Windows::Foundation::{TimeSpan, TypedEventHandler, Uri};
use super::bindings::Windows::Media::ClosedCaptioning::{ClosedCaptionOpacity, ClosedCaptionProperties, ClosedCaptionSize};
use super::bindings::Windows::Media::Core::{
    CodecCategory, CodecKind, CodecQuery, CodecSubtypes, MediaDecoderStatus, MediaSource, TimedMetadataKind,
    TimedMetadataTrack, TimedTextCue,
};
use super::bindings::Windows::Media::Playback::{
    IMediaPlaybackSource, MediaPlaybackItem, MediaPlaybackState, MediaPlayer, MediaPlayerError,
    TimedMetadataTrackPresentationMode,
};
use super::bindings::Windows::Media::{
    MediaPlaybackStatus, MediaPlaybackType, SystemMediaTransportControls, SystemMediaTransportControlsButton,
};
use super::bindings::Windows::Media::Streaming::Adaptive::{
    AdaptiveMediaSource, AdaptiveMediaSourceCreationResult, AdaptiveMediaSourceCreationStatus,
};
use super::bindings::Windows::Web::Http::{HttpClient, HttpCompletionOption, HttpMethod, HttpRequestMessage};
use super::{CoreState, CORE, DISPATCHER};
use crate::media::Report;
use crate::protocol::{PlayerCommand, PlayerId, PlayerProp, SessionAction, TrackKind, Value, WidgetId};

/// The one clock this arm ticks on: positions every POSITION_TICK_MS, and
/// kaya's caption renderer and the visibility read at every tick.
const TICK_MS: i64 = 50;

pub(super) struct WinPlayer {
    player: MediaPlayer,
    /// Bumped per source: an event raised for an older item says nothing.
    generation: Arc<AtomicU64>,
    item: Option<MediaPlaybackItem>,
    /// The item's source, closed when the item is replaced or released.
    source: Option<MediaSource>,
    /// An adaptive source's own AdaptiveMediaSource and the HttpClient it
    /// downloads through (`load`).
    adaptive_source: Option<AdaptiveMediaSource>,
    http: Option<HttpClient>,
    speed: f64,
    size: (u32, u32),
    /// The platform's clock is running (its PlaybackState reads Playing).
    playing: bool,
    last_position: Option<std::time::Instant>,
    /// kaya's caption renderer (docs/media-plan.md §3): the sidecar's
    /// boundaries the core handed over, and the text it answered last.
    caption_times: Vec<u64>,
    kaya_caption: String,
    /// The platform's own caption tracks: their indices among the item's
    /// timed metadata tracks, the selected one, and its current cue.
    caption_tracks: Vec<u32>,
    caption_selected: Option<u32>,
    platform_cue: String,
    /// An http(s) sidecar's fetch: its generation, 0 for none pending.
    fetch: Arc<AtomicU64>,
    fetch_url: String,
    /// The source is HLS or DASH, whose size is a placeholder until a frame.
    adaptive: bool,
    awaiting_size: bool,
    loaded: bool,
    looping: bool,
    duration_ms: u64,
    trail: Trail,
    /// SeekCompleted events raised, for the seek that never completes.
    seeks: Arc<AtomicU64>,
    /// The video edit list's start in 100 ns, which Media Foundation's clock
    /// runs ahead of the picture by (crate::edit_list; docs/traps.md).
    shift: Arc<AtomicI64>,
    /// An http(s) item's edit list is still being read; its open waits.
    shift_pending: bool,
    opened: bool,
    /// A seek issued while another has not completed waits for it
    /// (docs/deferred.md, the WinUI paused seek that leaves the old picture).
    seek_in_flight: bool,
    seek_held: Option<i64>,
    /// The app's last word was play: a frame step would pause it.
    play_asked: bool,
}

/// WHAT AN OPENING ITEM DID, per load, printed only when the open stalls
/// (docs/traps.md, the WinUI adaptive pipeline that goes idle): the source's and
/// the session's transitions and, for an adaptive source, every download
/// and diagnostic it raised, each stamped from the load. Once printed, every
/// later line is printed as it comes.
#[derive(Clone)]
struct Trail(Arc<std::sync::Mutex<TrailLines>>);

struct TrailLines {
    player: u64,
    generation: u64,
    since: std::time::Instant,
    lines: Vec<String>,
    live: bool,
}

const TRAIL_CAP: usize = 400;

impl Trail {
    fn new(player: u64) -> Self {
        Trail(Arc::new(std::sync::Mutex::new(TrailLines {
            player,
            generation: 0,
            since: std::time::Instant::now(),
            lines: Vec::new(),
            live: false,
        })))
    }

    fn restart(&self, generation: u64) {
        let Ok(mut t) = self.0.lock() else { return };
        t.generation = generation;
        t.since = std::time::Instant::now();
        t.lines.clear();
        t.live = false;
    }

    fn note(&self, generation: u64, text: String) {
        let Ok(mut t) = self.0.lock() else { return };
        if t.generation != generation {
            return;
        }
        let line = format!("+{}ms {text}", t.since.elapsed().as_millis());
        if t.live {
            eprintln!("KAYA_DIAG winui player {} open trail: {line}", t.player);
        }
        if t.lines.len() < TRAIL_CAP {
            t.lines.push(line);
        }
    }

    fn print(&self, generation: u64) {
        let Ok(mut t) = self.0.lock() else { return };
        if t.generation != generation {
            return;
        }
        eprintln!("KAYA_DIAG winui player {} open trail ({} lines, cap {TRAIL_CAP}):", t.player, t.lines.len());
        for line in &t.lines {
            eprintln!("KAYA_DIAG winui player {} open trail: {line}", t.player);
        }
        t.live = true;
    }
}

fn unix_ms() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis())
}

fn uri_text(uri: windows_core::Result<Uri>) -> String {
    uri.and_then(|u| u.Path()).map(|p| p.to_string()).unwrap_or_else(|e| format!("<uri: {}>", e.message()))
}

fn span_text(span: windows_core::Result<super::bindings::Windows::Foundation::IReference<TimeSpan>>) -> String {
    span.and_then(|r| r.Value()).map(|t| format!("{}ms", t.Duration / 10_000)).unwrap_or_else(|_| "-".to_owned())
}

fn statistics_text(
    stats: windows_core::Result<super::bindings::Windows::Media::Streaming::Adaptive::AdaptiveMediaSourceDownloadStatistics>,
) -> String {
    match stats {
        Ok(s) => format!(
            "{} bytes, headers {}, first byte {}, last byte {}",
            s.ContentBytesReceivedCount().map_or_else(|_| "?".to_owned(), |n| n.to_string()),
            span_text(s.TimeToHeadersReceived()),
            span_text(s.TimeToFirstByteReceived()),
            span_text(s.TimeToLastByteReceived())
        ),
        Err(e) => format!("no statistics ({})", e.message()),
    }
}

fn status_text(response: windows_core::Result<super::bindings::Windows::Web::Http::HttpResponseMessage>) -> String {
    response.and_then(|r| r.StatusCode()).map(|c| format!("HTTP {}", c.0)).unwrap_or_else(|_| "no response".to_owned())
}

/// An adaptive source's downloads and diagnostics, noted on the trail.
fn trail_adaptive(adaptive: &AdaptiveMediaSource, trail: &Trail, generation: u64) {
    use super::bindings::Windows::Media::Streaming::Adaptive::{
        AdaptiveMediaSourceDiagnosticAvailableEventArgs, AdaptiveMediaSourceDiagnostics,
        AdaptiveMediaSourceDownloadCompletedEventArgs, AdaptiveMediaSourceDownloadFailedEventArgs,
        AdaptiveMediaSourceDownloadRequestedEventArgs,
    };
    trail.note(generation, "adaptive source: watching its downloads".to_owned());
    let t = trail.clone();
    let _ = adaptive.DownloadRequested(&TypedEventHandler::new(
        move |_: windows_core::Ref<'_, AdaptiveMediaSource>,
              args: windows_core::Ref<'_, AdaptiveMediaSourceDownloadRequestedEventArgs>| {
            if let Some(a) = args.as_ref() {
                t.note(
                    generation,
                    format!(
                        "download requested #{} type {} {} offset {} length {}",
                        a.RequestId().unwrap_or(-1),
                        a.ResourceType().map_or(-1, |r| r.0),
                        uri_text(a.ResourceUri()),
                        a.ResourceByteRangeOffset().and_then(|r| r.Value()).map_or_else(|_| "-".to_owned(), |n| n.to_string()),
                        a.ResourceByteRangeLength().and_then(|r| r.Value()).map_or_else(|_| "-".to_owned(), |n| n.to_string())
                    ),
                );
            }
            Ok(())
        },
    ));
    let t = trail.clone();
    let _ = adaptive.DownloadCompleted(&TypedEventHandler::new(
        move |_: windows_core::Ref<'_, AdaptiveMediaSource>,
              args: windows_core::Ref<'_, AdaptiveMediaSourceDownloadCompletedEventArgs>| {
            if let Some(a) = args.as_ref() {
                t.note(
                    generation,
                    format!(
                        "download completed #{} {} {}: {}",
                        a.RequestId().unwrap_or(-1),
                        uri_text(a.ResourceUri()),
                        status_text(a.HttpResponseMessage()),
                        statistics_text(a.Statistics())
                    ),
                );
            }
            Ok(())
        },
    ));
    let t = trail.clone();
    let _ = adaptive.DownloadFailed(&TypedEventHandler::new(
        move |_: windows_core::Ref<'_, AdaptiveMediaSource>,
              args: windows_core::Ref<'_, AdaptiveMediaSourceDownloadFailedEventArgs>| {
            if let Some(a) = args.as_ref() {
                t.note(
                    generation,
                    format!(
                        "download FAILED #{} {} {} error {:#010x}: {}",
                        a.RequestId().unwrap_or(-1),
                        uri_text(a.ResourceUri()),
                        status_text(a.HttpResponseMessage()),
                        a.ExtendedError().map_or(0, |h| h.0 as u32),
                        statistics_text(a.Statistics())
                    ),
                );
            }
            Ok(())
        },
    ));
    let t = trail.clone();
    if let Ok(diagnostics) = adaptive.Diagnostics() {
        let _ = diagnostics.DiagnosticAvailable(&TypedEventHandler::new(
            move |_: windows_core::Ref<'_, AdaptiveMediaSourceDiagnostics>,
                  args: windows_core::Ref<'_, AdaptiveMediaSourceDiagnosticAvailableEventArgs>| {
                if let Some(a) = args.as_ref() {
                    t.note(
                        generation,
                        format!(
                            "diagnostic type {} {} error {:#010x}",
                            a.DiagnosticType().map_or(-1, |d| d.0),
                            uri_text(a.ResourceUri()),
                            a.ExtendedError().map_or(0, |h| h.0 as u32)
                        ),
                    );
                }
                Ok(())
            },
        ));
    }
}

pub(super) struct WinVideo {
    pub(super) host: Grid,
    /// The box at its natural size inside a Viewbox, which scales it to the
    /// host's room at its aspect (docs/media-plan.md §3), the element and the
    /// self-view's picture inside it: the host has no Width or Height of its
    /// own, so it takes the natural size where it fits, and where it does not
    /// its height follows its width.
    frame: Grid,
    pub(super) element: MediaPlayerElement,
    /// What assistive clients read (docs/media-plan.md §3): an empty Image
    /// over the picture, since a named MediaPlayerElement publishes only a
    /// NamedContainerAutomationPeer, a Group (measured 2026-09-30).
    pub(super) ax: super::bindings::Microsoft::UI::Xaml::Controls::Image,
    /// A self-view's picture: the frames kaya already holds, drawn through
    /// the core's one BT.601 rule (docs/traps.md, the WinUI self-view colour).
    picture: super::bindings::Microsoft::UI::Xaml::Controls::Image,
    caption_box: Grid,
    caption: TextBlock,
    player: Option<u64>,
    /// The capture this view previews (docs/capture-plan.md §3); a view
    /// shows a player or a capture, never both (the core holds that).
    capture: Option<u64>,
    /// The picture's natural size last given, and the app's packed aspect
    /// (0 none): the box is the core's rule over both (docs/media-plan.md §3).
    natural: std::cell::Cell<(u32, u32)>,
    aspect: std::cell::Cell<i64>,
}

#[derive(Default)]
struct SessionView {
    player: Option<u64>,
    offered: u32,
    stated: u32,
    title: String,
    artist: String,
    album: String,
    artwork: String,
}

#[derive(Default)]
pub(super) struct MediaState {
    players: HashMap<u64, WinPlayer>,
    videos: HashMap<u64, WinVideo>,
    /// The video views in creation order, the registry `video#index` reads.
    pub(super) video_ids: Vec<u64>,
    session: SessionView,
    /// The SMTC a session with no player speaks through, and the one
    /// currently configured (`None` while the app has no session).
    window_smtc: Option<SystemMediaTransportControls>,
    live_smtc: Option<SystemMediaTransportControls>,
    wired_smtcs: Vec<SystemMediaTransportControls>,
    timer: Option<DispatcherQueueTimer>,
    /// The process's display request (keep_awake), and whether it is set.
    power_request: Option<isize>,
    awake: bool,
    /// Each open capture's preview (capture.rs).
    capture_previews: HashMap<u64, CapturePreview>,
}

/// An open camera's self-view: the frames' size, whether it mirrors, and the
/// bitmap its latest frame was drawn into, made at the first frame.
pub(super) struct CapturePreview {
    pub(super) size: (u32, u32),
    pub(super) mirror: bool,
    bitmap: Option<(super::bindings::Microsoft::UI::Xaml::Media::Imaging::WriteableBitmap, (u32, u32))>,
}

impl CapturePreview {
    pub(super) fn new(size: (u32, u32), mirror: bool) -> Self {
        CapturePreview { size, mirror, bitmap: None }
    }
}

/// Remote commands that reached this process's SMTC handler: session_send's
/// proof that the system delivered what it was asked to send.
static ARRIVALS: AtomicU64 = AtomicU64::new(0);

/// Run `f` on the UI thread with the core, once whoever holds it has
/// returned. Every platform media event is raised off the UI thread.
pub(super) fn post<F: FnOnce(&mut CoreState) + Send + 'static>(f: F) {
    let Some(dispatcher) = DISPATCHER.get() else { return };
    let cell = std::sync::Mutex::new(Some(f));
    let handler = DispatcherQueueHandler::new(move || {
        let Some(f) = cell.lock().unwrap().take() else { return Ok(()) };
        let busy = CORE.with(|slot| match slot.try_borrow_mut() {
            Ok(mut core) => {
                if let Some(core) = core.as_mut() {
                    crate::fault::guard("a media event", || f(core));
                }
                None
            }
            Err(_) => Some(f),
        });
        if let Some(f) = busy {
            post(f);
        }
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

fn ms_of(span: TimeSpan) -> u64 {
    (span.Duration.max(0) / 10_000) as u64
}

fn span_of(ms: u64) -> TimeSpan {
    TimeSpan { Duration: (ms as i64).saturating_mul(10_000) }
}

/// The platform's clock as the picture's time (docs/traps.md, the edit-list
/// entry); every read of `Position` goes through here.
fn shown_ms(span: TimeSpan, shift: &AtomicI64) -> u64 {
    ms_of(TimeSpan { Duration: span.Duration.saturating_sub(shift.load(Ordering::SeqCst)) })
}

/// At its end Media Foundation's clock stops at `NaturalDuration`, which is
/// the edit's length, so a shifted clock there reads the item's end, not the
/// edit before it. An unshifted clock is left alone: `tick` reads an adaptive
/// item's end from that clock running past the duration.
fn position_ms(p: &WinPlayer) -> u64 {
    let Ok(at) = p.player.PlaybackSession().and_then(|s| s.Position()) else { return 0 };
    if p.shift.load(Ordering::SeqCst) != 0 && p.duration_ms > 0 && ms_of(at) >= p.duration_ms {
        return p.duration_ms;
    }
    shown_ms(at, &p.shift)
}

/// THE ONE DOOR every player report takes: the core's state machine, then
/// the session and the keep-awake follow it, so the system's playback
/// status moves on every transition (tools/check-verbs.py holds every
/// `media_report` call inside here).
fn report(core: &mut CoreState, player: u64, report: Report) {
    let overdue = report == Report::Overdue;
    let (published, _) = core.scene.media_report(PlayerId(player), report);
    // A PLAYER THAT TIMED OUT IS TORN DOWN (docs/media-plan.md §7c).
    let torn_down = overdue && crate::media::timed_out(&published);
    for occ in published {
        core.occurrences.send(occ);
    }
    if torn_down {
        if let Err(e) = load(core, player, "") {
            eprintln!("KAYA_DIAG winui player {player}: tearing down the timed-out item failed: {}", e.message());
        }
    }
    session_follow(core);
    keep_awake(core);
}

fn live(core: &CoreState, player: u64, generation: u64) -> bool {
    core.media.players.get(&player).is_some_and(|p| p.generation.load(Ordering::SeqCst) == generation)
}

// ---- the player (docs/media-plan.md §2) -----------------------------------

pub(super) fn create_player(core: &mut CoreState, id: u64) -> windows_core::Result<()> {
    let player = MediaPlayer::new()?;
    player.SetAutoPlay(false)?;
    // THE APP OWNS PLAY STATE (§2 rule 3): with the command manager on,
    // Windows drives the player from the flyout itself, past the core's
    // routing; the session's system half is configured by hand instead.
    player.CommandManager()?.SetIsEnabled(false)?;
    player.SystemMediaTransportControls()?.SetIsEnabled(false)?;
    let generation = Arc::new(AtomicU64::new(0));
    let trail = Trail::new(id);
    let g = generation.clone();
    let t = trail.clone();
    player.MediaOpened(&TypedEventHandler::<MediaPlayer, windows_core::IInspectable>::new(move |_, _| {
        let at = g.load(Ordering::SeqCst);
        t.note(at, "MediaOpened".to_owned());
        post(move |core| opened(core, id, at));
        Ok(())
    }))?;
    let g = generation.clone();
    let t = trail.clone();
    player.MediaFailed(&TypedEventHandler::new(
        move |_, args: windows_core::Ref<'_, super::bindings::Windows::Media::Playback::MediaPlayerFailedEventArgs>| {
            let at = g.load(Ordering::SeqCst);
            let Some(args) = args.as_ref() else { return Ok(()) };
            let error = args.Error().unwrap_or(MediaPlayerError::Unknown);
            let code = args.ExtendedErrorCode().map(|h| h.0).unwrap_or(0);
            t.note(at, format!("MediaFailed {} {:#010x}", error.0, code as u32));
            let message = args.ErrorMessage().map(|m| m.to_string()).unwrap_or_default();
            post(move |core| {
                if !live(core, id, at) {
                    return;
                }
                // RAW FACTS: the error, its extended HRESULT and the
                // platform's sentence; crate::media::failure_reason decides.
                let detail = if message.trim().is_empty() {
                    format!("MediaPlayerError {} with {:#010x}", error.0, code as u32)
                } else {
                    format!("{} ({:#010x})", message.trim(), code as u32)
                };
                report(
                    core,
                    id,
                    Report::Failed {
                        domain: "MediaPlayerError".to_owned(),
                        code: i64::from(error.0),
                        underlying: i64::from(code as u32),
                        detail,
                    },
                );
            });
            Ok(())
        },
    ))?;
    let g = generation.clone();
    player.MediaEnded(&TypedEventHandler::<MediaPlayer, windows_core::IInspectable>::new(move |_, _| {
        let at = g.load(Ordering::SeqCst);
        post(move |core| {
            if live(core, id, at) {
                if let Some(p) = core.media.players.get_mut(&id) {
                    p.playing = false;
                }
                report(core, id, Report::Ended);
                ask_caption(core, id);
            }
        });
        Ok(())
    }))?;
    let session = player.PlaybackSession()?;
    let g = generation.clone();
    let t = trail.clone();
    session.PlaybackStateChanged(&TypedEventHandler::new(
        move |sender: windows_core::Ref<'_, super::bindings::Windows::Media::Playback::MediaPlaybackSession>, _| {
            let at = g.load(Ordering::SeqCst);
            let Some(sender) = sender.as_ref() else { return Ok(()) };
            let state = sender.PlaybackState().unwrap_or(MediaPlaybackState::None);
            t.note(at, format!("session state {}", state.0));
            post(move |core| state_changed(core, id, at, state));
            Ok(())
        },
    ))?;
    for (started, name) in [(true, "buffering started"), (false, "buffering ended")] {
        let g = generation.clone();
        let t = trail.clone();
        let handler = TypedEventHandler::new(move |_, _| {
            t.note(g.load(Ordering::SeqCst), name.to_owned());
            Ok(())
        });
        if started {
            session.BufferingStarted(&handler)?;
        } else {
            session.BufferingEnded(&handler)?;
        }
    }
    let g = generation.clone();
    session.NaturalVideoSizeChanged(&TypedEventHandler::new(move |_, _| {
        let at = g.load(Ordering::SeqCst);
        post(move |core| size_settled(core, id, at));
        Ok(())
    }))?;
    let g = generation.clone();
    let t = trail.clone();
    let seeks = Arc::new(AtomicU64::new(0));
    let done = seeks.clone();
    let shift = Arc::new(AtomicI64::new(0));
    let ahead = shift.clone();
    session.SeekCompleted(&TypedEventHandler::new(
        move |sender: windows_core::Ref<'_, super::bindings::Windows::Media::Playback::MediaPlaybackSession>, _| {
            let at = g.load(Ordering::SeqCst);
            let Some(sender) = sender.as_ref() else { return Ok(()) };
            let ms = sender.Position().map_or(0, |pos| shown_ms(pos, &ahead));
            t.note(at, format!("seek completed at {ms} ms"));
            done.fetch_add(1, Ordering::SeqCst);
            post(move |core| {
                if live(core, id, at) {
                    if let Some(p) = core.media.players.get_mut(&id) {
                        p.seek_in_flight = false;
                        if let Some(held) = p.seek_held.take() {
                            p.seek_in_flight = true;
                            if let Err(e) = p.player.PlaybackSession().and_then(|s| s.SetPosition(TimeSpan { Duration: held })) {
                                eprintln!("KAYA_DIAG winui player {id}: the held seek failed: {}", e.message());
                            }
                            return;
                        }
                    }
                    report(core, id, Report::Seeked(ms));
                    ask_caption(core, id);
                    platform_cue(core, id);
                    // A PAUSED SEEK'S PICTURE IS DRAWN BY A FRAME STEP THERE
                    // AND BACK: the seek alone left the old picture on 3 of
                    // 10 (docs/traps.md, the WinUI paused seek); a step
                    // raises no SeekCompleted.
                    if let Some(p) = core.media.players.get(&id) {
                        if !p.playing && !p.play_asked && p.seek_held.is_none() && p.size.0 > 0 {
                            if let Err(e) = p.player.StepForwardOneFrame().and_then(|()| p.player.StepBackwardOneFrame()) {
                                eprintln!("KAYA_DIAG winui player {id}: the paused seek's frame step failed: {}", e.message());
                            }
                        }
                    }
                }
            });
            Ok(())
        },
    ))?;
    core.media.players.insert(
        id,
        WinPlayer {
            player,
            generation,
            item: None,
            source: None,
            adaptive_source: None,
            http: None,
            speed: 1.0,
            size: (0, 0),
            playing: false,
            last_position: None,
            caption_times: Vec::new(),
            kaya_caption: String::new(),
            caption_tracks: Vec::new(),
            caption_selected: None,
            platform_cue: String::new(),
            fetch: Arc::new(AtomicU64::new(0)),
            fetch_url: String::new(),
            adaptive: false,
            awaiting_size: false,
            loaded: false,
            looping: false,
            duration_ms: 0,
            trail,
            seeks,
            shift,
            shift_pending: false,
            opened: false,
            seek_in_flight: false,
            seek_held: None,
            play_asked: false,
        },
    );
    ensure_timer(core)?;
    Ok(())
}

/// This process's TCP connections to `endpoint` (host:port) by state, as
/// `netstat -ano` lists them: what a source stuck opening was waiting on.
fn connections_to(endpoint: &str) -> String {
    if !endpoint.contains(':') {
        return format!("<{endpoint:?} names no port>");
    }
    let Ok(out) = std::process::Command::new("netstat.exe").args(["-ano", "-p", "tcp"]).output() else {
        return "<netstat did not run>".to_owned();
    };
    let pid = std::process::id().to_string();
    let mut states: std::collections::BTreeMap<String, Vec<String>> = std::collections::BTreeMap::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() == 5 && cols[2] == endpoint && cols[4] == pid {
            let port = cols[1].rsplit(':').next().unwrap_or("?");
            states.entry(cols[3].to_owned()).or_default().push(port.to_owned());
        }
    }
    if states.is_empty() { "none".to_owned() } else { format!("{states:?}") }
}

/// A replaced source is closed, so it stops fetching.
fn close_source(source: Option<MediaSource>, adaptive: Option<AdaptiveMediaSource>) {
    if let Some(source) = source {
        if let Err(e) = source.Close() {
            eprintln!("KAYA_DIAG winui: closing the replaced media source failed: {}", e.message());
        }
    }
    if let Some(adaptive) = adaptive {
        if let Err(e) = adaptive.Close() {
            eprintln!("KAYA_DIAG winui: closing the replaced adaptive source failed: {}", e.message());
        }
    }
}

fn state_changed(core: &mut CoreState, id: u64, generation: u64, state: MediaPlaybackState) {
    if !live(core, id, generation) {
        return;
    }
    let playing = match state {
        MediaPlaybackState::Playing => true,
        MediaPlaybackState::Paused => false,
        _ => return,
    };
    if let Some(p) = core.media.players.get_mut(&id) {
        p.playing = playing;
    }
    report(core, id, Report::Rate(playing));
    if !playing {
        ask_caption(core, id);
    }
}

/// The item opened. Its picture size is settled first: an adaptive source
/// states a placeholder (1920x1080 for the local HLS trees, measured) until
/// its first frame decodes, when the session raises NaturalVideoSizeChanged.
fn opened(core: &mut CoreState, id: u64, generation: u64) {
    if !live(core, id, generation) {
        return;
    }
    let Some(p) = core.media.players.get_mut(&id) else { return };
    p.opened = true;
    // THE FIRST AUDIO TRACK, the file's default: Media Foundation's MP4
    // source selects the LAST one and ignores the default disposition
    // (measured on h264_2audio.mp4, eng default, SelectedIndex 1).
    if let Some(item) = &p.item {
        if let Ok(audios) = item.AudioTracks() {
            if audios.Size().unwrap_or(0) > 1 && audios.SelectedIndex().unwrap_or(0) != 0 {
                let _ = audios.SetSelectedIndex(0);
            }
        }
    }
    let has_video = p.item.as_ref().and_then(|i| i.VideoTracks().ok()).and_then(|v| v.Size().ok()).unwrap_or(0) > 0;
    if has_video && p.adaptive {
        p.awaiting_size = true;
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(SIZE_WAIT_MS));
            post(move |core| finish_open(core, id, generation));
        });
        return;
    }
    finish_open(core, id, generation);
}

/// When a source still opening says where it stands.
const OPEN_REPORT_MS: u64 = 5000;

/// When a seek that has not completed says where it stands.
const SEEK_REPORT_MS: u64 = 5000;

/// How far past its duration an item's clock may run before its end is read.
const END_OVERRUN_MS: u64 = 500;

/// How long an adaptive item's first frame may take to state its size.
const SIZE_WAIT_MS: u64 = 3000;

fn size_settled(core: &mut CoreState, id: u64, generation: u64) {
    if live(core, id, generation) && core.media.players.get(&id).is_some_and(|p| p.awaiting_size) {
        finish_open(core, id, generation);
    }
}

/// MF_MT_MINIMUM_DISPLAY_APERTURE: the part of a decoded frame that is the
/// picture. The HEVC extension decodes the 90-row clip to 96 rows and says
/// so only here (docs/probes/media-suite-2026-09-29.md).
const DISPLAY_APERTURE: windows_core::GUID = windows_core::GUID::from_u128(0xd7388766_18fe_48c6_a177_ee894867c8c4);

fn aperture(track: &super::bindings::Windows::Media::Core::VideoTrack) -> Option<(u32, u32)> {
    let props = track.GetEncodingProperties().ok()?.Properties().ok()?;
    if !props.HasKey(DISPLAY_APERTURE).ok()? {
        return None;
    }
    let value: super::bindings::Windows::Foundation::IPropertyValue = props.Lookup(DISPLAY_APERTURE).ok()?.cast().ok()?;
    let mut blob = windows_core::Array::<u8>::new();
    value.GetUInt8Array(&mut blob).ok()?;
    aperture_size(&blob)
}

/// An MFVideoArea's size: two MFOffsets, then a SIZE of two i32s.
pub(super) fn aperture_size(area: &[u8]) -> Option<(u32, u32)> {
    let cx = i32::from_le_bytes(area.get(8..12)?.try_into().ok()?);
    let cy = i32::from_le_bytes(area.get(12..16)?.try_into().ok()?);
    (cx > 0 && cy > 0).then_some((cx as u32, cy as u32))
}

/// The DECODABILITY CHECK (docs/media-plan.md §7a) — Windows plays the audio
/// of a file whose video decoder is missing and reports nothing, and only
/// each track's `SupportInfo.DecoderStatus` says so — then the tracks.
fn finish_open(core: &mut CoreState, id: u64, generation: u64) {
    if !live(core, id, generation) || core.media.players.get(&id).is_none_or(|p| p.loaded || p.shift_pending) {
        return;
    }
    let read = (|| -> windows_core::Result<(u64, (u32, u32), bool, String)> {
        let p = &core.media.players[&id];
        let session = p.player.PlaybackSession()?;
        let duration = ms_of(session.NaturalDuration()?);
        let mut size = (session.NaturalVideoWidth()?, session.NaturalVideoHeight()?);
        let mut why = String::new();
        if let Some(item) = &p.item {
            let videos = item.VideoTracks()?;
            for i in 0..videos.Size()? {
                let track = videos.GetAt(i)?;
                if i == 0 {
                    let stream = track.GetEncodingProperties().and_then(|e| Ok((e.Width()?, e.Height()?)));
                    let shown = aperture(&track);
                    eprintln!(
                        "KAYA_DIAG winui player {id}: session {size:?}, stream {stream:?}, aperture {shown:?}, \
                         waited {}",
                        p.awaiting_size
                    );
                    if let Some(shown) = shown {
                        size = shown;
                    } else if let (Ok(stream), false) = (stream, p.awaiting_size) {
                        if stream.0 > 0 && stream.1 > 0 {
                            size = stream;
                        }
                    }
                }
                let status = track.SupportInfo()?.DecoderStatus()?;
                if status != MediaDecoderStatus::FullySupported && why.is_empty() {
                    why = format!("the video track's DecoderStatus is {}", decoder_status_name(status));
                }
            }
            let audios = item.AudioTracks()?;
            for i in 0..audios.Size()? {
                let status = audios.GetAt(i)?.SupportInfo()?.DecoderStatus()?;
                if status != MediaDecoderStatus::FullySupported && why.is_empty() {
                    why = format!("audio track {} has DecoderStatus {}", i + 1, decoder_status_name(status));
                }
            }
        }
        Ok((duration, size, !why.is_empty(), why))
    })();
    let (duration_ms, size, undecodable, detail) = match read {
        Ok(read) => read,
        Err(e) => (0, (0, 0), true, format!("reading the opened item failed: {}", e.message())),
    };
    if let Some(p) = core.media.players.get_mut(&id) {
        p.size = size;
        p.duration_ms = duration_ms;
        p.loaded = true;
        p.awaiting_size = false;
    }
    report(core, id, Report::Loaded { duration_ms, size, undecodable, detail });
    report_tracks(core, id);
    ask_caption(core, id);
    for video in core.media.videos.values().filter(|v| v.player == Some(id)) {
        let _ = natural_size(video, size);
    }
}

fn decoder_status_name(status: MediaDecoderStatus) -> String {
    match status {
        MediaDecoderStatus::FullySupported => "FullySupported".to_owned(),
        MediaDecoderStatus::UnsupportedSubtype => "UnsupportedSubtype".to_owned(),
        MediaDecoderStatus::UnsupportedEncoderProperties => "UnsupportedEncoderProperties".to_owned(),
        MediaDecoderStatus::Degraded => "Degraded".to_owned(),
        other => format!("{}", other.0),
    }
}

/// A resolved source (the core checked a local one exists): a file:// or
/// http(s) URL, "" for none.
fn load(core: &mut CoreState, id: u64, url: &str) -> windows_core::Result<()> {
    let Some(p) = core.media.players.get_mut(&id) else { return Ok(()) };
    let generation = p.generation.fetch_add(1, Ordering::SeqCst) + 1;
    p.size = (0, 0);
    p.playing = false;
    p.caption_tracks.clear();
    p.caption_selected = None;
    p.platform_cue.clear();
    p.last_position = None;
    p.loaded = false;
    p.awaiting_size = false;
    p.duration_ms = 0;
    p.shift.store(0, Ordering::SeqCst);
    p.shift_pending = false;
    p.opened = false;
    p.seek_in_flight = false;
    p.seek_held = None;
    p.play_asked = false;
    let path = url.split(['?', '#']).next().unwrap_or(url).to_ascii_lowercase();
    p.adaptive = path.ends_with(".m3u8") || path.ends_with(".mpd");
    let previous = p.source.take();
    let previous_adaptive = p.adaptive_source.take();
    p.http = None;
    p.item = None;
    if url.is_empty() {
        p.player.SetSource(None::<&IMediaPlaybackSource>)?;
        close_source(previous, previous_adaptive);
        return Ok(());
    }
    p.trail.restart(generation);
    p.trail.note(generation, format!("source set to {url} at unix ms {}", unix_ms()));
    let uri = Uri::CreateUri(&HSTRING::from(url))?;
    if p.adaptive {
        // AN ADAPTIVE SOURCE IS AN AdaptiveMediaSource OF ITS OWN, ON ITS
        // OWN HttpClient, whose downloads the trail can see (docs/traps.md,
        // the WinUI adaptive pipeline that goes idle).
        p.player.SetSource(None::<&IMediaPlaybackSource>)?;
        close_source(previous, previous_adaptive);
        std::thread::spawn(move || {
            // SAFETY: this thread's own apartment, ended with the thread.
            unsafe { super::CoInitializeEx(std::ptr::null(), 0x0) };
            let made = (|| -> windows_core::Result<(AdaptiveMediaSourceCreationResult, HttpClient)> {
                let client = HttpClient::new()?;
                let result = AdaptiveMediaSource::CreateFromUriWithDownloaderAsync(&uri, &client)?.join()?;
                Ok((result, client))
            })();
            post(move |core| adaptive_created(core, id, generation, made));
        });
    } else {
        read_shift(core, id, generation, url);
        let source = MediaSource::CreateFromUri(&uri)?;
        attach(core, id, generation, source)?;
        close_source(previous, previous_adaptive);
    }
    keep_awake(core);
    let endpoint = url
        .split("://")
        .nth(1)
        .and_then(|rest| rest.split('/').next())
        .unwrap_or("")
        .to_owned();
    std::thread::spawn(move || {
        // WHAT A SOURCE STILL OPENING IS DOING, for the leg's log: its
        // states, its connections and its trail (docs/traps.md, the WinUI
        // adaptive pipeline that goes idle).
        std::thread::sleep(std::time::Duration::from_millis(OPEN_REPORT_MS));
        let connections = connections_to(&endpoint);
        post(move |core| {
            if live(core, id, generation) && core.media.players.get(&id).is_some_and(|p| !p.loaded) {
                let p = &core.media.players[&id];
                let state = match &p.source {
                    Some(source) => format!("{}", source.State().map(|s| s.0).unwrap_or(-1)),
                    None => "none yet (the AdaptiveMediaSource is still being created)".to_owned(),
                };
                let session = p.player.PlaybackSession().and_then(|s| s.PlaybackState());
                eprintln!(
                    "KAYA_DIAG winui player {id}: still opening after {OPEN_REPORT_MS} ms — MediaSource.State {state} \
                     (0 Initial, 1 Opening, 2 Opened, 3 Failed), session state {:?}; this process's TCP \
                     connections to {endpoint} by local port: {connections}; unix ms {}",
                    session.as_ref().map(|s| s.0),
                    unix_ms()
                );
                p.trail.print(generation);
            }
        });
        std::thread::sleep(std::time::Duration::from_millis(crate::media::TIMEOUT_MS - OPEN_REPORT_MS));
        post(move |core| {
            if live(core, id, generation) {
                report(core, id, Report::Overdue);
            }
        });
    });
    Ok(())
}

/// MEDIA FOUNDATION IGNORES AN MP4 EDIT LIST (docs/traps.md): a local file's
/// video `elst` is read here, an http(s) one's by byte range on a thread with
/// the open held until it answers.
fn read_shift(core: &mut CoreState, id: u64, generation: u64, url: &str) {
    let Some(p) = core.media.players.get_mut(&id) else { return };
    if let Some(path) = crate::edit_list::file_url_path(url) {
        let read = std::fs::File::open(&path)
            .map_err(|e| format!("opening {path}: {e}"))
            .and_then(|f| crate::edit_list::video_shift(&mut crate::edit_list::LocalFile(f)));
        settle_shift(p, id, url, read);
        return;
    }
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return;
    }
    p.shift_pending = true;
    let url = url.to_owned();
    std::thread::spawn(move || {
        // SAFETY: this thread's own apartment, ended with the thread.
        unsafe { super::CoInitializeEx(std::ptr::null(), 0x0) };
        let read = (|| -> windows_core::Result<HttpRange> {
            Ok(HttpRange { client: HttpClient::new()?, uri: Uri::CreateUri(&HSTRING::from(url.as_str()))? })
        })()
        .map_err(|e| format!("starting the byte-range client: {}", e.message()))
        .and_then(|mut range| crate::edit_list::video_shift(&mut range));
        post(move |core| {
            if !live(core, id, generation) {
                return;
            }
            let Some(p) = core.media.players.get_mut(&id) else { return };
            p.shift_pending = false;
            settle_shift(p, id, &url, read);
            if p.opened {
                finish_open(core, id, generation);
            }
        });
    });
}

fn settle_shift(p: &mut WinPlayer, id: u64, url: &str, read: Result<Option<crate::edit_list::Shift>, String>) {
    match read {
        Ok(Some(crate::edit_list::Shift(hns))) => {
            p.shift.store(hns, Ordering::SeqCst);
            eprintln!("KAYA_DIAG winui player {id}: {url}'s video edit list starts {hns} hns in; the clock is moved by it");
        }
        Ok(None) => {}
        Err(why) => eprintln!("KAYA_DIAG winui player {id}: {url}'s edit list was not read, so the clock is not moved: {why}"),
    }
}

/// An http(s) file read by `Range` requests, for its `moov`.
struct HttpRange {
    client: HttpClient,
    uri: Uri,
}

impl crate::edit_list::ReadAt for HttpRange {
    fn read_at(&mut self, offset: u64, len: usize) -> Result<Vec<u8>, String> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let last = offset + len as u64 - 1;
        let got = (|| -> windows_core::Result<Result<Vec<u8>, String>> {
            let request = HttpRequestMessage::Create(&HttpMethod::Get()?, &self.uri)?;
            request.Headers()?.TryAppendWithoutValidation(&HSTRING::from("Range"), &HSTRING::from(format!("bytes={offset}-{last}")))?;
            let response = self.client.SendRequestWithOptionAsync(&request, HttpCompletionOption::ResponseHeadersRead)?.join()?;
            match response.StatusCode()?.0 {
                206 => {}
                416 => return Ok(Ok(Vec::new())),
                status => return Ok(Err(format!("HTTP {status} to `Range: bytes={offset}-{last}`"))),
            }
            let buffer = response.Content()?.ReadAsBufferAsync()?.join()?;
            let n = buffer.Length()? as usize;
            let access: windows::Win32::System::WinRT::IBufferByteAccess = buffer.cast()?;
            // SAFETY: the buffer owns `n` bytes and outlives the copy.
            let bytes = unsafe { std::slice::from_raw_parts(access.Buffer()?, n).to_vec() };
            Ok(Ok(bytes))
        })();
        got.map_err(|e| format!("`Range: bytes={offset}-{last}` failed: {}", e.message()))?
    }
}

/// The adaptive source's creation answered: attach it, or report why not.
fn adaptive_created(
    core: &mut CoreState,
    id: u64,
    generation: u64,
    made: windows_core::Result<(AdaptiveMediaSourceCreationResult, HttpClient)>,
) {
    if !live(core, id, generation) {
        if let Ok((result, _)) = made {
            if let Ok(adaptive) = result.MediaSource() {
                let _ = adaptive.Close();
            }
        }
        return;
    }
    let trail = core.media.players[&id].trail.clone();
    let failed = |domain: &str, code: i64, underlying: i64, detail: String| Report::Failed {
        domain: domain.to_owned(),
        code,
        underlying,
        detail,
    };
    let (result, client) = match made {
        Ok(made) => made,
        Err(e) => {
            trail.note(generation, format!("AdaptiveMediaSource creation threw {:#010x}", e.code().0 as u32));
            let r = failed("Windows.Web.Http", i64::from(e.code().0 as u32), 0, e.message().to_string());
            report(core, id, r);
            return;
        }
    };
    let status = result.Status().map_or(-1, |s| s.0);
    let http = result.HttpResponseMessage().and_then(|r| r.StatusCode()).map_or(0, |c| c.0);
    let extended = result.ExtendedError().map_or(0, |h| h.0 as u32);
    trail.note(generation, format!("AdaptiveMediaSource created: status {status}, HTTP {http}, error {extended:#010x}"));
    if status != AdaptiveMediaSourceCreationStatus::Success.0 {
        let detail = format!("AdaptiveMediaSourceCreationStatus {status}, HTTP {http}, error {extended:#010x}");
        let r = failed("AdaptiveMediaSourceCreationStatus", i64::from(status), i64::from(http), detail);
        report(core, id, r);
        return;
    }
    let attached = (|| -> windows_core::Result<()> {
        let adaptive = result.MediaSource()?;
        trail_adaptive(&adaptive, &trail, generation);
        let source = MediaSource::CreateFromAdaptiveMediaSource(&adaptive)?;
        if let Some(p) = core.media.players.get_mut(&id) {
            p.adaptive_source = Some(adaptive);
            p.http = Some(client);
        }
        attach(core, id, generation, source)
    })();
    if let Err(e) = attached {
        let r = failed("AdaptiveMediaSource", i64::from(e.code().0 as u32), 0, e.message().to_string());
        report(core, id, r);
    }
}

/// A source becomes the player's item.
fn attach(core: &mut CoreState, id: u64, generation: u64, source: MediaSource) -> windows_core::Result<()> {
    let Some(p) = core.media.players.get_mut(&id) else { return Ok(()) };
    let t = p.trail.clone();
    source.StateChanged(&TypedEventHandler::new(
        move |_: windows_core::Ref<'_, MediaSource>,
              args: windows_core::Ref<'_, super::bindings::Windows::Media::Core::MediaSourceStateChangedEventArgs>| {
            let Some(args) = args.as_ref() else { return Ok(()) };
            t.note(
                generation,
                format!("source state {} -> {}", args.OldState().map_or(-1, |s| s.0), args.NewState().map_or(-1, |s| s.0)),
            );
            Ok(())
        },
    ))?;
    let item = MediaPlaybackItem::Create(&source)?;
    let g = p.generation.clone();
    item.TimedMetadataTracksChanged(&TypedEventHandler::new(move |_, _| {
        let at = g.load(Ordering::SeqCst);
        post(move |core| {
            if live(core, id, at) {
                report_tracks(core, id);
            }
        });
        Ok(())
    }))?;
    let g = p.generation.clone();
    item.AudioTracksChanged(&TypedEventHandler::new(move |_, _| {
        let at = g.load(Ordering::SeqCst);
        post(move |core| {
            if live(core, id, at) {
                report_tracks(core, id);
            }
        });
        Ok(())
    }))?;
    p.player.SetSource(&item)?;
    p.item = Some(item);
    p.source = Some(source);
    Ok(())
}

pub(super) fn set_player_prop(core: &mut CoreState, id: u64, prop: PlayerProp, value: Value) -> windows_core::Result<()> {
    match (prop, value) {
        (PlayerProp::Source, Value::Str(url)) => load(core, id, &url)?,
        (PlayerProp::Captions, Value::Str(url)) => fetch_captions(core, id, url),
        (PlayerProp::Speed, Value::F64(x)) => {
            if let Some(p) = core.media.players.get_mut(&id) {
                p.speed = x;
                p.player.PlaybackSession()?.SetPlaybackRate(x)?;
            }
        }
        (PlayerProp::Volume, Value::F64(x)) => {
            if let Some(p) = core.media.players.get(&id) {
                p.player.SetVolume(x)?;
            }
        }
        (PlayerProp::Muted, Value::Bool(on)) => {
            if let Some(p) = core.media.players.get(&id) {
                p.player.SetIsMuted(on)?;
            }
        }
        (PlayerProp::Loop, Value::Bool(on)) => {
            if let Some(p) = core.media.players.get_mut(&id) {
                p.looping = on;
                p.player.SetIsLoopingEnabled(on)?;
            }
        }
        (prop, value) => panic!("kaya: winui player {id} got {prop:?} = {value:?}, which the core never sends"),
    }
    Ok(())
}

pub(super) fn command(core: &mut CoreState, id: u64, command: PlayerCommand) -> windows_core::Result<()> {
    let Some(p) = core.media.players.get(&id) else { return Ok(()) };
    match command {
        PlayerCommand::Play => {
            p.player.PlaybackSession()?.SetPlaybackRate(p.speed)?;
            p.player.Play()?;
            if let Some(p) = core.media.players.get_mut(&id) {
                p.play_asked = true;
            }
        }
        PlayerCommand::Pause => {
            p.player.Pause()?;
            if let Some(p) = core.media.players.get_mut(&id) {
                p.play_asked = false;
            }
        }
        PlayerCommand::Seek(ms) => {
            p.trail.note(p.generation.load(Ordering::SeqCst), format!("seek to {ms} ms asked"));
            // A SEEK THAT NEVER COMPLETES says so, with the trail
            // (docs/traps.md, the WinUI adaptive pipeline that goes idle).
            let (seeks, before, generation) = (p.seeks.clone(), p.seeks.load(Ordering::SeqCst), p.generation.load(Ordering::SeqCst));
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(SEEK_REPORT_MS));
                if seeks.load(Ordering::SeqCst) == before {
                    post(move |core| {
                        if live(core, id, generation) {
                            let p = &core.media.players[&id];
                            let session = p.player.PlaybackSession().and_then(|s| s.PlaybackState());
                            eprintln!(
                                "KAYA_DIAG winui player {id}: the seek to {ms} ms has not completed after {SEEK_REPORT_MS} ms \
                                 — session state {:?}; unix ms {}",
                                session.as_ref().map(|s| s.0),
                                unix_ms()
                            );
                            p.trail.print(generation);
                        }
                    });
                }
                std::thread::sleep(std::time::Duration::from_millis(crate::media::TIMEOUT_MS - SEEK_REPORT_MS));
                post(move |core| {
                    if live(core, id, generation) {
                        report(core, id, Report::Overdue);
                    }
                });
            });
            let at = span_of(ms).Duration.saturating_add(p.shift.load(Ordering::SeqCst)).max(0);
            let held = p.seek_in_flight;
            if !held {
                p.player.PlaybackSession()?.SetPosition(TimeSpan { Duration: at })?;
            }
            if let Some(p) = core.media.players.get_mut(&id) {
                if held {
                    p.seek_held = Some(at);
                } else {
                    p.seek_in_flight = true;
                }
            }
        }
    }
    Ok(())
}

pub(super) fn release(core: &mut CoreState, id: u64) -> windows_core::Result<()> {
    let Some(p) = core.media.players.remove(&id) else { return Ok(()) };
    p.generation.fetch_add(1, Ordering::SeqCst);
    p.fetch.fetch_add(1, Ordering::SeqCst);
    let _ = p.player.Pause();
    close_source(p.source.clone(), p.adaptive_source.clone());
    for video in core.media.videos.values_mut().filter(|v| v.player == Some(id)) {
        video.player = None;
        video.element.SetMediaPlayer(None::<&MediaPlayer>)?;
        show_caption(video, "")?;
    }
    if core.media.session.player == Some(id) {
        core.media.session.player = None;
    }
    // A player set on an element is the app's to close (§2's table): kaya
    // closes it here, after every element let it go.
    p.player.Close()?;
    keep_awake(core);
    Ok(())
}

// ---- the tracks and the platform's own captions (§3) ----------------------

/// A language as BCP 47 through the platform's own canonicalizer, `und`
/// for a track that names none.
fn language_tag(raw: &HSTRING) -> String {
    let raw = raw.to_string();
    let raw = raw.trim();
    if raw.is_empty() {
        return "und".to_owned();
    }
    windows::Globalization::Language::CreateLanguage(&HSTRING::from(raw))
        .and_then(|l| l.LanguageTag())
        .map(|t| t.to_string())
        .unwrap_or_else(|_| raw.to_owned())
}

fn is_caption_kind(track: &TimedMetadataTrack) -> bool {
    track
        .TimedMetadataKind()
        .is_ok_and(|k| k == TimedMetadataKind::Caption || k == TimedMetadataKind::Subtitle)
}

fn report_tracks(core: &mut CoreState, id: u64) {
    let read = (|| -> windows_core::Result<Option<Report>> {
        let Some(p) = core.media.players.get_mut(&id) else { return Ok(None) };
        // NOTHING READS THE ITEM'S TRACKS BEFORE IT OPENS (docs/traps.md, the
        // HLS item that never raised MediaOpened); `finish_open` reports them.
        if !p.loaded {
            return Ok(None);
        }
        let Some(item) = p.item.clone() else { return Ok(None) };
        let audios = item.AudioTracks()?;
        let mut audio = Vec::new();
        for i in 0..audios.Size()? {
            audio.push(language_tag(&audios.GetAt(i)?.Language()?));
        }
        let picked = audios.SelectedIndex()?;
        let audio_selected = (picked >= 0 && (picked as usize) < audio.len()).then_some(picked as usize);
        let timed = item.TimedMetadataTracks()?;
        let mut captions = Vec::new();
        let mut indices = Vec::new();
        let mut caption_selected = None;
        for i in 0..timed.Size()? {
            let track = timed.GetAt(i)?;
            if !is_caption_kind(&track) {
                continue;
            }
            if timed.GetPresentationMode(i)? == TimedMetadataTrackPresentationMode::PlatformPresented {
                caption_selected = Some(captions.len());
            }
            captions.push(language_tag(&track.Language()?));
            indices.push(i);
            if !p.caption_tracks.contains(&i) {
                let g = p.generation.clone();
                let t = p.trail.clone();
                let cue = TypedEventHandler::new(move |_, _| {
                    let at = g.load(Ordering::SeqCst);
                    t.note(at, format!("caption track {i} cue entered or exited"));
                    post(move |core| {
                        if live(core, id, at) {
                            platform_cue(core, id);
                        }
                    });
                    Ok(())
                });
                track.CueEntered(&cue)?;
                track.CueExited(&cue)?;
            }
        }
        p.caption_tracks = indices;
        p.caption_selected = caption_selected.map(|at| p.caption_tracks[at]);
        Ok(Some(Report::Tracks { audio, captions, audio_selected, caption_selected }))
    })();
    match read {
        Ok(Some(tracks)) => report(core, id, tracks),
        Ok(None) => {}
        Err(e) => eprintln!("KAYA_DIAG winui player {id}: reading the item's tracks failed: {}", e.message()),
    }
}

pub(super) fn select_track(core: &mut CoreState, id: u64, kind: TrackKind, index: u32) -> windows_core::Result<()> {
    let Some(p) = core.media.players.get(&id) else { return Ok(()) };
    p.trail.note(p.generation.load(Ordering::SeqCst), format!("select {kind:?} track {index}"));
    let Some(item) = p.item.clone() else { return Ok(()) };
    match kind {
        TrackKind::Audio => item.AudioTracks()?.SetSelectedIndex(index as i32 - 1)?,
        TrackKind::Caption => {
            let timed = item.TimedMetadataTracks()?;
            for (at, i) in p.caption_tracks.iter().enumerate() {
                let mode = if index as usize == at + 1 {
                    TimedMetadataTrackPresentationMode::PlatformPresented
                } else {
                    TimedMetadataTrackPresentationMode::Disabled
                };
                timed.SetPresentationMode(*i, mode)?;
            }
        }
    }
    report_tracks(core, id);
    platform_cue(core, id);
    Ok(())
}

/// The platform's own current cue on its selected caption track: the
/// track's ACTIVE cues, which Windows fills after a paused seek too, while
/// its `Cues` list stays empty for an HLS rendition (measured 2026-09-30).
fn platform_cue(core: &mut CoreState, id: u64) {
    let text = (|| -> windows_core::Result<String> {
        let p = &core.media.players[&id];
        let (Some(item), Some(index)) = (&p.item, p.caption_selected) else { return Ok(String::new()) };
        let active = item.TimedMetadataTracks()?.GetAt(index)?.ActiveCues()?;
        let mut lines = Vec::new();
        for i in 0..active.Size()? {
            if let Ok(cue) = active.GetAt(i)?.cast::<TimedTextCue>() {
                let text_lines = cue.Lines()?;
                for l in 0..text_lines.Size()? {
                    lines.push(text_lines.GetAt(l)?.Text()?.to_string());
                }
            }
        }
        Ok(lines.join("\n"))
    })()
    .unwrap_or_default();
    let Some(p) = core.media.players.get_mut(&id) else { return };
    if p.platform_cue != text {
        p.trail.note(p.generation.load(Ordering::SeqCst), format!("platform cue now {text:?}"));
        p.platform_cue = text.clone();
        report(core, id, Report::Cue(text));
    }
}

// ---- kaya's caption renderer (§3): the core times, WinUI draws ------------

pub(super) fn caption_times(core: &mut CoreState, id: u64, times: Vec<u64>) {
    if let Some(p) = core.media.players.get_mut(&id) {
        p.caption_times = times;
    }
    ask_caption(core, id);
}

fn ask_caption(core: &mut CoreState, id: u64) {
    let Some(p) = core.media.players.get(&id) else { return };
    let text = if p.caption_times.is_empty() {
        String::new()
    } else {
        let now = position_ms(p);
        let (text, published) = core.scene.caption_at(PlayerId(id), now);
        for occ in published {
            core.occurrences.send(occ);
        }
        text
    };
    let Some(p) = core.media.players.get_mut(&id) else { return };
    if p.kaya_caption != text {
        p.kaya_caption = text.clone();
        for video in core.media.videos.values().filter(|v| v.player == Some(id)) {
            if let Err(e) = show_caption(video, &text) {
                eprintln!("KAYA_DIAG winui caption overlay: {}", e.message());
            }
        }
    }
}

/// The overlay kaya's renderer draws over a video view, in the user's
/// caption style (Settings > Accessibility > Captions, read through
/// ClosedCaptionProperties).
fn show_caption(video: &WinVideo, text: &str) -> windows_core::Result<()> {
    video.caption.SetText(&HSTRING::from(text))?;
    if text.is_empty() {
        video.caption_box.SetVisibility(Visibility::Collapsed)?;
        return Ok(());
    }
    let opacity = |o: ClosedCaptionOpacity, default: u8| match o {
        ClosedCaptionOpacity::OneHundredPercent => 255,
        ClosedCaptionOpacity::SeventyFivePercent => 191,
        ClosedCaptionOpacity::TwentyFivePercent => 64,
        ClosedCaptionOpacity::ZeroPercent => 0,
        _ => default,
    };
    let mut ink = ClosedCaptionProperties::ComputedFontColor()?;
    ink.A = opacity(ClosedCaptionProperties::FontOpacity()?, 255);
    let mut ground = ClosedCaptionProperties::ComputedBackgroundColor()?;
    ground.A = opacity(ClosedCaptionProperties::BackgroundOpacity()?, 255);
    let scale = match ClosedCaptionProperties::FontSize()? {
        ClosedCaptionSize::FiftyPercent => 0.5,
        ClosedCaptionSize::OneHundredFiftyPercent => 1.5,
        ClosedCaptionSize::TwoHundredPercent => 2.0,
        _ => 1.0,
    };
    video.caption.SetForeground(&SolidColorBrush::CreateInstanceWithColor(ink)?)?;
    video.caption.SetFontSize(15.0 * scale)?;
    video.caption_box.SetBackground(&SolidColorBrush::CreateInstanceWithColor(ground)?)?;
    video.caption_box.SetVisibility(Visibility::Visible)
}

/// An http(s) sidecar, fetched with the platform's own HTTP client and
/// handed to the core as text; "" cancels a fetch still pending
/// (docs/media-plan.md §3, RULED 2026-09-30).
fn fetch_captions(core: &mut CoreState, id: u64, url: String) {
    let Some(p) = core.media.players.get_mut(&id) else { return };
    let at = p.fetch.fetch_add(1, Ordering::SeqCst) + 1;
    p.fetch_url = url.clone();
    if url.is_empty() {
        return;
    }
    let fetch = p.fetch.clone();
    std::thread::spawn(move || {
        // SAFETY: this thread's own apartment, ended with the thread.
        unsafe { super::CoInitializeEx(std::ptr::null(), 0x0) };
        let got = (|| -> Result<Result<String, (String, i64, String)>, windows_core::Error> {
            let client = HttpClient::new()?;
            let response = client.GetAsync(&Uri::CreateUri(&HSTRING::from(url.as_str()))?)?.join()?;
            let status = response.StatusCode()?.0;
            if !(200..300).contains(&status) {
                let phrase = response.ReasonPhrase().map(|p| p.to_string()).unwrap_or_default();
                return Ok(Err(("http".to_owned(), i64::from(status), phrase)));
            }
            Ok(Ok(response.Content()?.ReadAsStringAsync()?.join()?.to_string()))
        })();
        let answer = match got {
            Ok(Ok(text)) => Report::CaptionsText { url: url.clone(), text },
            Ok(Err((domain, code, detail))) => {
                Report::CaptionsFailed { url: url.clone(), domain, code, underlying: 0, detail }
            }
            Err(e) => Report::CaptionsFailed {
                url: url.clone(),
                domain: "Windows.Web.Http".to_owned(),
                code: i64::from(e.code().0 as u32),
                underlying: 0,
                detail: e.message().to_string(),
            },
        };
        post(move |core| {
            if fetch.load(Ordering::SeqCst) == at && core.media.players.contains_key(&id) {
                report(core, id, answer);
            }
        });
    });
}

// ---- the clock: positions, kaya's captions, visibility --------------------

fn ensure_timer(core: &mut CoreState) -> windows_core::Result<()> {
    if core.media.timer.is_some() {
        return Ok(());
    }
    let Some(dispatcher) = DISPATCHER.get() else { return Ok(()) };
    let timer = dispatcher.0.CreateTimer()?;
    timer.SetInterval(TimeSpan { Duration: TICK_MS * 10_000 })?;
    timer.SetIsRepeating(true)?;
    timer.Tick(&TypedEventHandler::new(move |_, _| {
        CORE.with(|slot| {
            if let Ok(mut core) = slot.try_borrow_mut() {
                if let Some(core) = core.as_mut() {
                    crate::fault::guard("the media clock", || tick(core));
                }
            }
        });
        Ok(())
    }))?;
    timer.Start()?;
    core.media.timer = Some(timer);
    Ok(())
}

fn tick(core: &mut CoreState) {
    let due: Vec<u64> = core.media.players.iter().filter(|(_, p)| p.playing).map(|(id, _)| *id).collect();
    for id in due {
        let Some(p) = core.media.players.get_mut(&id) else { continue };
        let now = std::time::Instant::now();
        let every = std::time::Duration::from_millis(crate::media::POSITION_TICK_MS);
        if p.last_position.is_none_or(|last| now.duration_since(last) >= every) {
            p.last_position = Some(now);
            let ms = position_ms(p);
            report(core, id, Report::Position(ms));
            // AN ADAPTIVE CLOCK THAT RUNS PAST THE END: the local DASH and
            // HLS items, played pooled, kept `Playing` with the position past
            // 9 s of a 2 s item and no MediaEnded (measured 2026-09-30,
            // docs/traps.md), so the end is the clock passing the duration.
            let p = &core.media.players[&id];
            if !p.looping && p.duration_ms > 0 && ms > p.duration_ms + END_OVERRUN_MS {
                eprintln!("KAYA_DIAG winui player {id}: the clock read {ms} ms past a {} ms item with no MediaEnded", p.duration_ms);
                let _ = p.player.Pause();
                if let Some(p) = core.media.players.get_mut(&id) {
                    p.playing = false;
                }
                report(core, id, Report::Ended);
                continue;
            }
        }
        ask_caption(core, id);
        if core.media.players.get(&id).is_some_and(|p| p.caption_selected.is_some()) {
            platform_cue(core, id);
        }
    }
    let views: Vec<u64> = core.media.video_ids.clone();
    for widget in views {
        let shown = core.media.videos.get(&widget).map_or(0.0, |v| shown_fraction(core, v));
        for occ in core.scene.video_visible(WidgetId(widget), shown) {
            core.occurrences.send(occ);
        }
    }
}

/// How much of a video view shows inside every scroll it sits in: its box
/// against each ancestor ScrollViewer's, in the window root's coordinates.
fn shown_fraction(core: &CoreState, video: &WinVideo) -> f64 {
    (|| -> windows_core::Result<f64> {
        let root = core.window.Content()?;
        let element: FrameworkElement = video.host.cast()?;
        let (w, h) = (element.ActualWidth()?, element.ActualHeight()?);
        if w <= 0.0 || h <= 0.0 || element.Visibility()? != Visibility::Visible {
            return Ok(0.0);
        }
        let rect = |e: &FrameworkElement| -> windows_core::Result<(f64, f64, f64, f64)> {
            let at = e
                .cast::<UIElement>()?
                .TransformToVisual(&root)?
                .TransformPoint(super::bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
            let (x, y) = (f64::from(at.X), f64::from(at.Y));
            Ok((x, y, x + e.ActualWidth()?, y + e.ActualHeight()?))
        };
        let (mut l, mut t, mut r, mut b) = rect(&element)?;
        let mut node: Option<super::bindings::Microsoft::UI::Xaml::DependencyObject> =
            VisualTreeHelper::GetParent(&element).ok();
        let mut in_tree = false;
        while let Some(at) = node {
            if at.cast::<UIElement>().ok().as_ref() == Some(&root) {
                in_tree = true;
                break;
            }
            if let Ok(viewer) = at.cast::<super::bindings::Microsoft::UI::Xaml::Controls::ScrollViewer>() {
                let (vl, vt, vr, vb) = rect(&viewer.cast()?)?;
                (l, t, r, b) = (l.max(vl), t.max(vt), r.min(vr), b.min(vb));
            }
            node = VisualTreeHelper::GetParent(&at).ok();
        }
        if !in_tree || r <= l || b <= t {
            return Ok(0.0);
        }
        Ok(((r - l) * (b - t)) / (w * h))
    })()
    .unwrap_or(0.0)
}

// ---- the video view (§3) --------------------------------------------------

pub(super) fn create_video(core: &mut CoreState, id: u64) -> windows_core::Result<WinVideo> {
    let host = Grid::new()?;
    let element = MediaPlayerElement::new()?;
    // NO PLATFORM CONTROLS (docs/media-plan.md §3): the app draws its own,
    // and the element's transport bar would be a second, unasked one
    // (tools/check-verbs.py holds this line).
    element.SetAreTransportControlsEnabled(false)?;
    element.SetAutoPlay(false)?;
    element.SetStretch(Stretch::Uniform)?;
    let caption_box = Grid::new()?;
    caption_box.SetHorizontalAlignment(HorizontalAlignment::Center)?;
    caption_box.SetVerticalAlignment(VerticalAlignment::Bottom)?;
    caption_box.SetPadding(Thickness { Left: 6.0, Top: 2.0, Right: 6.0, Bottom: 2.0 })?;
    caption_box.SetMargin(Thickness { Left: 8.0, Top: 8.0, Right: 8.0, Bottom: 8.0 })?;
    caption_box.SetVisibility(Visibility::Collapsed)?;
    let caption = TextBlock::new()?;
    caption.SetTextWrapping(TextWrapping::Wrap)?;
    caption_box.Children()?.Append(&caption)?;
    let ax = super::bindings::Microsoft::UI::Xaml::Controls::Image::new()?;
    ax.SetIsHitTestVisible(false)?;
    ax.SetStretch(Stretch::Fill)?;
    super::bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAccessibilityView(
        &element,
        super::bindings::Microsoft::UI::Xaml::Automation::Peers::AccessibilityView::Raw,
    )?;
    let picture = super::bindings::Microsoft::UI::Xaml::Controls::Image::new()?;
    picture.SetIsHitTestVisible(false)?;
    picture.SetStretch(Stretch::Uniform)?;
    let frame = Grid::new()?;
    let extent = super::bindings::Microsoft::UI::Xaml::Controls::Viewbox::new()?;
    extent.SetStretch(Stretch::Uniform)?;
    extent.SetChild(&frame)?;
    extent.SetIsHitTestVisible(false)?;
    extent.SetHorizontalAlignment(HorizontalAlignment::Left)?;
    // The picture's elements live in the box's own frame, so the Viewbox
    // scales them with it: a host child would answer its own picture's height
    // and the Grid would take that over the box's (docs/media-plan.md §3).
    frame.Children()?.Append(&element)?;
    frame.Children()?.Append(&picture)?;
    host.Children()?.Append(&extent)?;
    host.Children()?.Append(&ax)?;
    host.Children()?.Append(&caption_box)?;
    let video = WinVideo {
        host,
        frame,
        element,
        ax,
        picture,
        caption_box,
        caption,
        player: None,
        capture: None,
        natural: std::cell::Cell::new((0, 0)),
        aspect: std::cell::Cell::new(0),
    };
    natural_size(&video, (0, 0))?;
    core.media.video_ids.push(id);
    Ok(video)
}

pub(super) fn register_video(core: &mut CoreState, id: u64, video: WinVideo) {
    core.media.videos.insert(id, video);
}

/// The video views' elements in creation order: the registry `video#index`
/// and `video@id` resolve through.
#[cfg(feature = "harness")]
pub(super) fn elements(core: &CoreState) -> Vec<super::bindings::Microsoft::UI::Xaml::Controls::Image> {
    core.media.video_ids.iter().filter_map(|id| core.media.videos.get(id)).map(|v| v.ax.clone()).collect()
}

/// The view's natural size: its picture's, 320x180 until one is known —
/// the SwiftUI arm's `kayaVideoNatural` — no wider than the room it is
/// given, its height following its width (docs/media-plan.md §3).
fn natural_size(video: &WinVideo, size: (u32, u32)) -> windows_core::Result<()> {
    video.natural.set(size);
    let picture = if size.0 == 0 || size.1 == 0 { (320, 180) } else { size };
    let (w, h) = crate::media::video_view_box(picture, video.aspect.get());
    let (w, h) = (f64::from(w), f64::from(h));
    video.frame.SetWidth(w)?;
    video.frame.SetHeight(h)?;
    video.host.SetWidth(f64::NAN)?;
    video.host.SetMaxWidth(w)?;
    video.host.SetHeight(f64::NAN)
}

pub(super) fn destroy_video(core: &mut CoreState, id: u64) {
    if let Some(i) = core.media.video_ids.iter().position(|v| *v == id) {
        core.media.video_ids.remove(i);
    }
    if let Some(video) = core.media.videos.remove(&id) {
        let _ = video.element.SetMediaPlayer(None::<&MediaPlayer>);
    }
    keep_awake(core);
}

/// The app's box ratio (docs/media-plan.md §3): the box follows it at once.
pub(super) fn set_aspect(core: &CoreState, id: u64, aspect: i64) -> windows_core::Result<()> {
    let Some(video) = core.media.videos.get(&id) else { return Ok(()) };
    video.aspect.set(aspect);
    natural_size(video, video.natural.get())
}

pub(super) fn set_fit(core: &CoreState, id: u64, fit: i64) -> windows_core::Result<()> {
    let Some(video) = core.media.videos.get(&id) else { return Ok(()) };
    let stretch = match crate::wire::vocab_name(crate::wire::FITS, fit) {
        Some("cover") => Stretch::UniformToFill,
        Some("fill") => Stretch::Fill,
        _ => Stretch::Uniform,
    };
    video.picture.SetStretch(stretch)?;
    video.element.SetStretch(stretch)
}

/// SetVideoPlayer: the core already holds the one-view rule on the batch's
/// end state, so a player moving between two views in one batch is taken
/// off the first here before the second shows it.
pub(super) fn set_video_player(core: &mut CoreState, widget: u64, player: Option<u64>) -> windows_core::Result<()> {
    // A view previewing a capture is not cleared by its player going to none.
    if player.is_none() && core.media.videos.get(&widget).is_some_and(|v| v.capture.is_some()) {
        return Ok(());
    }
    if let Some(p) = player {
        for (other, video) in core.media.videos.iter_mut() {
            if *other != widget && video.player == Some(p) {
                video.player = None;
                video.element.SetMediaPlayer(None::<&MediaPlayer>)?;
                show_caption(video, "")?;
            }
        }
    }
    let shown = player.and_then(|p| core.media.players.get(&p)).map(|p| (p.player.clone(), p.size, p.kaya_caption.clone()));
    let Some(video) = core.media.videos.get_mut(&widget) else { return Ok(()) };
    mirror(&video.element, false)?;
    match &shown {
        Some((media, size, caption)) => {
            video.player = player;
            video.element.SetMediaPlayer(media)?;
            natural_size(video, *size)?;
            show_caption(video, caption)?;
        }
        None => {
            video.player = None;
            video.element.SetMediaPlayer(None::<&MediaPlayer>)?;
            natural_size(video, (0, 0))?;
            show_caption(video, "")?;
        }
    }
    keep_awake(core);
    Ok(())
}

// ---- the capture's preview (docs/capture-plan.md §3) -------------------------

/// The self-view's mirror (rule 4): WinUI mirrors nothing itself, so kaya
/// scales the element by -1 on x about its centre; the frames never mirror.
fn mirror(element: &impl windows_core::Interface, on: bool) -> windows_core::Result<()> {
    let element: UIElement = element.cast()?;
    if on {
        let scale = super::bindings::Microsoft::UI::Xaml::Media::ScaleTransform::new()?;
        scale.SetScaleX(-1.0)?;
        element.SetRenderTransformOrigin(super::bindings::Windows::Foundation::Point { X: 0.5, Y: 0.5 })?;
        element.SetRenderTransform(&scale.cast::<super::bindings::Microsoft::UI::Xaml::Media::Transform>()?)
    } else {
        element.SetRenderTransform(None::<&super::bindings::Microsoft::UI::Xaml::Media::Transform>)
    }
}

/// A view showing `capture` shows its preview now, or nothing.
fn show_capture(video: &WinVideo, preview: Option<&CapturePreview>) -> windows_core::Result<()> {
    video.element.SetMediaPlayer(None::<&MediaPlayer>)?;
    mirror(&video.element, false)?;
    match preview {
        Some(p) => {
            match &p.bitmap {
                Some((b, _)) => video.picture.SetSource(b)?,
                None => video.picture.SetSource(None::<&super::bindings::Microsoft::UI::Xaml::Media::ImageSource>)?,
            }
            natural_size(video, crate::capture::self_view_natural(p.size, 0))?;
            mirror(&video.picture, p.mirror)
        }
        None => {
            video.picture.SetSource(None::<&super::bindings::Microsoft::UI::Xaml::Media::ImageSource>)?;
            natural_size(video, crate::capture::self_view_natural((0, 0), 0))?;
            mirror(&video.picture, false)
        }
    }
}

/// capture.rs's word that a capture's preview started or went out: every
/// view previewing it follows, and so does the keep-awake.
pub(super) fn capture_preview(core: &mut CoreState, capture: u64, preview: Option<CapturePreview>) {
    match preview {
        Some(p) => core.media.capture_previews.insert(capture, p),
        None => core.media.capture_previews.remove(&capture),
    };
    let now = core.media.capture_previews.get(&capture);
    for video in core.media.videos.values().filter(|v| v.capture == Some(capture)) {
        if let Err(e) = show_capture(video, now) {
            eprintln!("KAYA_DIAG winui capture {capture}: the view could not show the preview: {}", e.message());
        }
    }
    keep_awake(core);
}

/// capture.rs's latest frame for an open preview, already BGRA8 and opaque:
/// written into the preview's bitmap, made or remade at the frame's size.
pub(super) fn capture_picture(core: &mut CoreState, capture: u64, width: u32, height: u32, bgra: &[u8]) -> windows_core::Result<()> {
    use super::bindings::Microsoft::UI::Xaml::Media::Imaging::WriteableBitmap;
    let Some(preview) = core.media.capture_previews.get_mut(&capture) else { return Ok(()) };
    let count = width as usize * height as usize * 4;
    let fresh = preview.bitmap.as_ref().is_none_or(|(_, size)| *size != (width, height));
    if fresh {
        preview.bitmap = Some((WriteableBitmap::CreateInstanceWithDimensions(width as i32, height as i32)?, (width, height)));
    }
    let Some((bitmap, _)) = preview.bitmap.clone() else { return Ok(()) };
    let buffer = bitmap.PixelBuffer()?;
    if (buffer.Capacity()? as usize) < count || bgra.len() < count {
        return Err(windows_core::Error::new(
            windows_core::HRESULT(0x8000_4005u32 as i32),
            format!("a {width}x{height} frame of {} bytes for a {}-byte bitmap", bgra.len(), buffer.Capacity()?),
        ));
    }
    let access: windows::Win32::System::WinRT::IBufferByteAccess = buffer.cast()?;
    // SAFETY: the bitmap's own pixel store, its capacity checked above.
    unsafe { std::ptr::copy_nonoverlapping(bgra.as_ptr(), access.Buffer()?, count) };
    bitmap.Invalidate()?;
    if fresh {
        let now = core.media.capture_previews.get(&capture);
        for video in core.media.videos.values().filter(|v| v.capture == Some(capture)) {
            show_capture(video, now)?;
        }
    }
    Ok(())
}

/// SetVideoCapture: the core holds the one-view rule on the batch's end
/// state, so a capture moving between two views is taken off the first.
pub(super) fn set_video_capture(core: &mut CoreState, widget: u64, capture: Option<u64>) -> windows_core::Result<()> {
    if let Some(c) = capture {
        for (other, video) in core.media.videos.iter_mut() {
            if *other != widget && video.capture == Some(c) {
                video.capture = None;
                show_capture(video, None)?;
            }
        }
    }
    let Some(video) = core.media.videos.get_mut(&widget) else { return Ok(()) };
    video.capture = capture;
    video.player = None;
    show_capture(video, capture.and_then(|c| core.media.capture_previews.get(&c)))?;
    show_caption(video, "")?;
    keep_awake(core);
    Ok(())
}

// ---- keep-awake (§2 rule 5) -----------------------------------------------

/// A player shown by a video view keeps the display awake while it plays
/// (§2 rule 5). NOT the item's display type: set to video on a playing
/// shown item it put nothing in the power manager's record
/// (`powercfg /requests` read `DISPLAY: None.` throughout, measured
/// 2026-09-30), so the arm holds the platform's own display request,
/// PowerSetRequest(PowerRequestDisplayRequired), exactly then.
fn keep_awake(core: &mut CoreState) {
    let want = core.media.players.iter().any(|(id, p)| {
        p.playing && p.size != (0, 0) && core.media.videos.values().any(|v| v.player == Some(*id))
    }) || core.media.videos.values().any(|v| v.capture.is_some_and(|c| core.media.capture_previews.contains_key(&c)));
    if want == core.media.awake {
        return;
    }
    let request = *core.media.power_request.get_or_insert_with(|| {
        let reason: Vec<u16> = "kaya: a video view shows a playing player or a camera".encode_utf16().chain(Some(0)).collect();
        let context = ReasonContext { version: 0, flags: 1, reason: reason.as_ptr(), _detailed: [0; 2] };
        // SAFETY: a filled REASON_CONTEXT whose string outlives the call.
        unsafe { PowerCreateRequest(&context) }
    });
    // SAFETY: the handle PowerCreateRequest answered, held for the process.
    let ok = unsafe { if want { PowerSetRequest(request, 0) } else { PowerClearRequest(request, 0) } };
    if ok == 0 {
        eprintln!("KAYA_DIAG winui keep-awake: {} the display request failed", if want { "setting" } else { "clearing" });
        return;
    }
    core.media.awake = want;
}

#[repr(C)]
struct ReasonContext {
    version: u32,
    flags: u32,
    reason: *const u16,
    _detailed: [usize; 2],
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn PowerCreateRequest(context: *const ReasonContext) -> isize;
    fn PowerSetRequest(request: isize, kind: i32) -> i32;
    fn PowerClearRequest(request: isize, kind: i32) -> i32;
}

// ---- the session (§5) -----------------------------------------------------

fn bit(action: u32) -> u32 {
    1 << action
}

pub(super) struct SessionSpec {
    pub(super) player: Option<u64>,
    pub(super) offered: u32,
    pub(super) stated: u32,
    pub(super) title: String,
    pub(super) artist: String,
    pub(super) album: String,
    pub(super) artwork: String,
}

pub(super) fn set_session(core: &mut CoreState, spec: SessionSpec) -> windows_core::Result<()> {
    let SessionSpec { player, offered, stated, title, artist, album, artwork } = spec;
    core.media.session = SessionView { player, offered, stated, title, artist, album, artwork };
    session_publish(core)
}

/// The SMTC the session speaks through: the attached player's own, or with
/// none attached the window's through ISystemMediaTransportControlsInterop
/// (GetForCurrentView throws in WinUI 3); every other player's is off, since
/// Windows shows a tab per enabled one.
fn session_publish(core: &mut CoreState) -> windows_core::Result<()> {
    let s = &core.media.session;
    let wanted = match s.player.and_then(|p| core.media.players.get(&p)) {
        Some(p) => Some(p.player.SystemMediaTransportControls()?),
        None if s.offered != 0 || s.stated != 0 => Some(window_smtc(core)?),
        None => None,
    };
    for (id, p) in &core.media.players {
        if core.media.session.player != Some(*id) {
            p.player.SystemMediaTransportControls()?.SetIsEnabled(false)?;
        }
    }
    if core.media.session.player.is_some() {
        if let Some(window) = &core.media.window_smtc {
            window.SetIsEnabled(false)?;
        }
    }
    if let Some(smtc) = &wanted {
        if !core.media.wired_smtcs.contains(smtc) {
            smtc.ButtonPressed(&TypedEventHandler::new(
                move |_, args: windows_core::Ref<'_, super::bindings::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs>| {
                    ARRIVALS.fetch_add(1, Ordering::SeqCst);
                    let Some(args) = args.as_ref() else { return Ok(()) };
                    let button = args.Button()?;
                    post(move |core| remote(core, button, 0));
                    Ok(())
                },
            ))?;
            smtc.PlaybackPositionChangeRequested(&TypedEventHandler::new(
                move |_, args: windows_core::Ref<'_, super::bindings::Windows::Media::PlaybackPositionChangeRequestedEventArgs>| {
                    ARRIVALS.fetch_add(1, Ordering::SeqCst);
                    let Some(args) = args.as_ref() else { return Ok(()) };
                    let at = ms_of(args.RequestedPlaybackPosition()?);
                    post(move |core| seek_requested(core, at));
                    Ok(())
                },
            ))?;
            core.media.wired_smtcs.push(smtc.clone());
        }
        let s = &core.media.session;
        let has = |a: SessionAction| s.offered & bit(crate::wire::session_action_raw(a).0) != 0;
        smtc.SetIsEnabled(true)?;
        smtc.SetIsPlayEnabled(has(SessionAction::Play))?;
        smtc.SetIsPauseEnabled(has(SessionAction::Pause))?;
        smtc.SetIsStopEnabled(has(SessionAction::Stop))?;
        smtc.SetIsNextEnabled(has(SessionAction::Next))?;
        smtc.SetIsPreviousEnabled(has(SessionAction::Previous))?;
        smtc.SetIsFastForwardEnabled(has(SessionAction::SeekForward))?;
        smtc.SetIsRewindEnabled(has(SessionAction::SeekBackward))?;
        let video = s.player.and_then(|p| core.media.players.get(&p)).is_some_and(|p| p.size != (0, 0));
        let display = smtc.DisplayUpdater()?;
        display.ClearAll()?;
        if video {
            display.SetType(MediaPlaybackType::Video)?;
            let props = display.VideoProperties()?;
            props.SetTitle(&HSTRING::from(s.title.as_str()))?;
            props.SetSubtitle(&HSTRING::from(s.artist.as_str()))?;
        } else {
            display.SetType(MediaPlaybackType::Music)?;
            let props = display.MusicProperties()?;
            props.SetTitle(&HSTRING::from(s.title.as_str()))?;
            props.SetArtist(&HSTRING::from(s.artist.as_str()))?;
            props.SetAlbumTitle(&HSTRING::from(s.album.as_str()))?;
        }
        if !s.artwork.is_empty() {
            let uri = Uri::CreateUri(&HSTRING::from(s.artwork.as_str()))?;
            display.SetThumbnail(
                &super::bindings::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(&uri)?,
            )?;
        }
        display.Update()?;
    }
    if let Some(old) = core.media.live_smtc.take() {
        if Some(&old) != wanted.as_ref() {
            old.SetIsEnabled(false)?;
        }
    }
    core.media.live_smtc = wanted;
    session_follow(core);
    Ok(())
}

fn window_smtc(core: &mut CoreState) -> windows_core::Result<SystemMediaTransportControls> {
    if let Some(smtc) = &core.media.window_smtc {
        return Ok(smtc.clone());
    }
    let native: super::IWindowNative = core.window.cast()?;
    let hwnd = native.window_handle()?;
    let interop = windows_core::factory::<
        SystemMediaTransportControls,
        windows::Win32::System::WinRT::ISystemMediaTransportControlsInterop,
    >()?;
    // SAFETY: a live top-level HWND this process owns, as GetForWindow asks.
    let smtc: SystemMediaTransportControls =
        unsafe { interop.GetForWindow(windows::Win32::Foundation::HWND(hwnd as *mut _))? };
    core.media.window_smtc = Some(smtc.clone());
    Ok(smtc)
}

/// After every report: the system's playback status is the core's answer
/// (docs/media-plan.md §5), set on every transition.
fn session_follow(core: &CoreState) {
    let Some(smtc) = &core.media.live_smtc else { return };
    let status = match core.scene.media_system_state() {
        1 => MediaPlaybackStatus::Playing,
        2 => MediaPlaybackStatus::Paused,
        _ => MediaPlaybackStatus::Stopped,
    };
    if let Err(e) = smtc.SetPlaybackStatus(status) {
        eprintln!("KAYA_DIAG winui session: setting the playback status failed: {}", e.message());
    }
}

/// A button from the system's media controls: THE CORE ROUTES IT
/// (docs/media-plan.md §5), and a default aimed at the attached player
/// runs here, on that player.
fn remote(core: &mut CoreState, button: SystemMediaTransportControlsButton, at_ms: u64) {
    let action = match button {
        SystemMediaTransportControlsButton::Play => SessionAction::Play,
        SystemMediaTransportControlsButton::Pause => SessionAction::Pause,
        SystemMediaTransportControlsButton::Stop => SessionAction::Stop,
        SystemMediaTransportControlsButton::Next => SessionAction::Next,
        SystemMediaTransportControlsButton::Previous => SessionAction::Previous,
        SystemMediaTransportControlsButton::FastForward => SessionAction::SeekForward,
        SystemMediaTransportControlsButton::Rewind => SessionAction::SeekBackward,
        _ => return,
    };
    route(core, action, at_ms);
}

fn seek_requested(core: &mut CoreState, at_ms: u64) {
    route(core, SessionAction::SeekTo(at_ms), at_ms);
}

fn route(core: &mut CoreState, action: SessionAction, _at_ms: u64) {
    use crate::media::Route;
    let routed = core.scene.media_route(action);
    eprintln!("KAYA_DIAG winui session: {action:?} routed {routed:?}");
    let run = |core: &mut CoreState, player: u64, command: PlayerCommand| {
        if let Err(e) = self::command(core, player, command) {
            eprintln!("KAYA_DIAG winui session: {command:?} on player {player} failed: {}", e.message());
        }
    };
    match routed {
        Route::App => core.occurrences.send(crate::protocol::Occurrence::SessionAction { action }),
        Route::Player(player, command) => run(core, player.0, command),
        Route::Replay(player) => {
            run(core, player.0, PlayerCommand::Seek(0));
            run(core, player.0, PlayerCommand::Play);
        }
        Route::NotOffered => {}
    }
}

// ---- the capability query (§8 ruling 1) -----------------------------------

/// Media Foundation's own decoders (CodecQuery) for each codec named, and a
/// fixed container list: MP4, QuickTime, Matroska/WebM, MP3, FLAC, WAV, HLS
/// and DASH are in-box, and Ogg is the Web Media Extensions package's
/// source (docs/probes/media-suite-2026-09-29.md), asked as its Vorbis
/// decoder, which only that package registers.
pub(crate) fn can_play(mime: &str, codecs: &str) -> bool {
    let mime = mime.trim().to_ascii_lowercase();
    let in_box = [
        "video/mp4", "audio/mp4", "video/quicktime", "video/webm", "audio/webm", "video/x-matroska",
        "audio/mpeg", "audio/mp3", "audio/flac", "audio/wav", "audio/x-wav", "audio/wave",
        "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "application/dash+xml",
    ];
    let mut needed: Vec<(CodecKind, String)> = Vec::new();
    if mime == "audio/ogg" || mime == "video/ogg" || mime == "application/ogg" {
        needed.push((CodecKind::Audio, VORBIS.to_owned()));
    } else if !in_box.contains(&mime.as_str()) {
        return false;
    }
    for codec in codecs.split(',').map(|c| c.trim().to_ascii_lowercase()).filter(|c| !c.is_empty()) {
        let prefix = codec.split('.').next().unwrap_or("");
        let wanted = match prefix {
            "avc1" | "avc3" => CodecSubtypes::VideoFormatH264().map(|s| (CodecKind::Video, s.to_string())),
            "hvc1" | "hev1" => CodecSubtypes::VideoFormatHevc().map(|s| (CodecKind::Video, s.to_string())),
            "vp09" | "vp9" => CodecSubtypes::VideoFormatVP90().map(|s| (CodecKind::Video, s.to_string())),
            "av01" => Ok((CodecKind::Video, AV1.to_owned())),
            "mp4a" => CodecSubtypes::AudioFormatAac().map(|s| (CodecKind::Audio, s.to_string())),
            "opus" => CodecSubtypes::AudioFormatOpus().map(|s| (CodecKind::Audio, s.to_string())),
            "mp3" => CodecSubtypes::AudioFormatMP3().map(|s| (CodecKind::Audio, s.to_string())),
            "flac" => CodecSubtypes::AudioFormatFlac().map(|s| (CodecKind::Audio, s.to_string())),
            "vorbis" => Ok((CodecKind::Audio, VORBIS.to_owned())),
            _ => return false,
        };
        match wanted {
            Ok(w) => needed.push(w),
            Err(_) => return false,
        }
    }
    in_mta(move || {
        let query = CodecQuery::new()?;
        for (kind, subtype) in &needed {
            let found = query.FindAllAsync(*kind, CodecCategory::Decoder, &HSTRING::from(subtype.as_str()))?.join()?;
            if found.Size()? == 0 {
                return Ok(false);
            }
        }
        Ok(true)
    })
    .unwrap_or(false)
}

/// MFVideoFormat_AV1 ('AV01'), which the metadata's CodecSubtypes lacks.
const AV1: &str = "{31305641-0000-0010-8000-00AA00389B71}";
/// MFAudioFormat_Vorbis ('VORB' over the audio base GUID).
const VORBIS: &str = "{8D2FD10B-5841-4A6B-8905-588FEC1ADED9}";

/// Run `f` in a multithreaded apartment of its own: CodecQuery, the global
/// session manager and HttpClient block on async operations, which the XAML
/// thread's ASTA may not do.
fn in_mta<T: Send + 'static>(f: impl FnOnce() -> windows_core::Result<T> + Send + 'static) -> windows_core::Result<T> {
    std::thread::spawn(move || {
        // SAFETY: this thread's own apartment, ended with the thread.
        unsafe { super::CoInitializeEx(std::ptr::null(), 0x0) };
        f()
    })
    .join()
    .unwrap_or_else(|_| Err(windows_core::Error::new(windows_core::HRESULT(0x8000_4005u32 as i32), "kaya: the media apartment's thread panicked")))
}

// ---- the harness's reads (docs/media-plan.md §6) --------------------------

#[cfg(feature = "harness")]
pub(super) mod stage {
    use super::*;

    /// The video view registry's widget at `index`.
    pub(in super::super) fn video_at(core: &CoreState, index: isize) -> Option<u64> {
        crate::harness::try_resolve(index, core.media.video_ids.len()).map(|i| core.media.video_ids[i])
    }

    pub(in super::super) fn host_of(core: &CoreState, widget: u64) -> Option<Grid> {
        core.media.videos.get(&widget).map(|v| v.host.clone())
    }

    /// expect_caption's read: what kaya's renderer drew where kaya draws (a
    /// sidecar is selected), the platform's own current cue otherwise.
    pub(in super::super) fn caption(core: &CoreState, widget: u64) -> String {
        let Some(p) = core.media.videos.get(&widget).and_then(|v| v.player).and_then(|p| core.media.players.get(&p))
        else {
            return String::new();
        };
        if p.caption_times.is_empty() { p.platform_cue.clone() } else { p.kaya_caption.clone() }
    }

    /// The video view's accessibility actions, by name: the player's own
    /// play and pause, the one path the view's commands take.
    pub(in super::super) fn ax_action(core: &mut CoreState, widget: u64, name: &str) -> Result<(), String> {
        let Some(player) = core.media.videos.get(&widget).and_then(|v| v.player) else {
            return Err(format!("video view {widget} shows no player, so it carries no actions"));
        };
        let command = match name {
            "Play" => PlayerCommand::Play,
            "Pause" => PlayerCommand::Pause,
            other => return Err(format!("the video view carries \"Play\" and \"Pause\", not {other:?}")),
        };
        super::command(core, player, command).map_err(|e| format!("{name}: {}", e.message()))
    }

    /// This process's identity as the system's session manager names it.
    fn ours(aumid: &str, source: &str) -> bool {
        let exe = std::env::current_exe()
            .ok()
            .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
            .unwrap_or_default();
        source == aumid || (!exe.is_empty() && source.eq_ignore_ascii_case(&exe))
    }

    /// The session the SYSTEM holds for this process, out of the global
    /// session manager every media flyout reads; Err names what it holds.
    fn system_session(
        aumid: String,
    ) -> windows_core::Result<Result<super::super::bindings::Windows::Media::Control::GlobalSystemMediaTransportControlsSession, String>>
    {
        use super::super::bindings::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager as Manager;
        let manager = Manager::RequestAsync()?.join()?;
        let sessions = manager.GetSessions()?;
        let mut names = Vec::new();
        for i in 0..sessions.Size()? {
            let session = sessions.GetAt(i)?;
            let source = session.SourceAppUserModelId()?.to_string();
            eprintln!("KAYA_DIAG winui session manager: a session from {source:?} (this process {aumid:?})");
            if ours(&aumid, &source) {
                return Ok(Ok(session));
            }
            names.push(source);
        }
        Ok(Err(format!("the system's session manager holds {names:?}, none of them this process ({aumid:?})")))
    }

    /// `"<title>" <state>` as the system's session manager reads this
    /// process's session back.
    pub(crate) fn now_playing(aumid: String) -> String {
        in_mta(move || {
            use super::super::bindings::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status;
            let session = match system_session(aumid)? {
                Ok(session) => session,
                Err(_) => return Ok("\"\" stopped".to_owned()),
            };
            let title = session.TryGetMediaPropertiesAsync()?.join()?.Title()?.to_string();
            let state = match session.GetPlaybackInfo()?.PlaybackStatus()? {
                Status::Playing => "playing",
                Status::Paused => "paused",
                _ => "stopped",
            };
            Ok(format!("{title:?} {state}"))
        })
        .unwrap_or_else(|e| format!("<the session manager: {}>", e.message()))
    }

    /// session_send (docs/media-plan.md §5): the command goes to the SYSTEM's
    /// session manager, which delivers it to this process's SMTC as a media
    /// key or the flyout's button would; refused unless the system names this
    /// process, and proven by the handler's own arrival count.
    pub(crate) fn session_send(aumid: String, action: &str) -> Result<(), String> {
        let action = action.to_owned();
        let before = ARRIVALS.load(Ordering::SeqCst);
        let sent = in_mta(move || {
            let session = match system_session(aumid)? {
                Ok(session) => session,
                Err(why) => return Ok(Err(why)),
            };
            let op = match action.as_str() {
                "play" => session.TryPlayAsync()?,
                "pause" => session.TryPauseAsync()?,
                "toggle" => session.TryTogglePlayPauseAsync()?,
                "stop" => session.TryStopAsync()?,
                "next" => session.TrySkipNextAsync()?,
                "previous" => session.TrySkipPreviousAsync()?,
                other => return Ok(Err(format!("session_send {other}: no such command"))),
            };
            Ok(Ok(op.join()?))
        })
        .map_err(|e| format!("the session manager: {}", e.message()))??;
        if !sent {
            return Err("the system's session manager answered false: the command is not enabled".to_owned());
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            if ARRIVALS.load(Ordering::SeqCst) > before {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        Err("the session manager answered true and no command reached this process's SMTC handler in 2 s".to_owned())
    }

    /// Whether the platform's own record — `powercfg /requests`, the power
    /// manager's list of display requests — names this process.
    pub(crate) fn display_awake() -> bool {
        let exe = std::env::current_exe()
            .ok()
            .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_ascii_lowercase()))
            .unwrap_or_default();
        let out = std::process::Command::new("powercfg.exe").arg("/requests").output();
        let Ok(out) = out else { return false };
        let text = String::from_utf8_lossy(&out.stdout).to_ascii_lowercase();
        let display = text.split("display:").nth(1).unwrap_or("");
        let section = display.split("system:").next().unwrap_or("");
        eprintln!("KAYA_DIAG winui display_awake: powercfg DISPLAY section {:?}", section.trim());
        !exe.is_empty() && section.contains(&exe)
    }
}

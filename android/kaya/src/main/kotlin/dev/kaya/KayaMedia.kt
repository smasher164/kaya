@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package dev.kaya

import android.content.Context
import android.content.Intent
import android.media.MediaCodecList
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.accessibility.CaptioningManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.datasource.DataSourceUtil
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import androidx.media3.exoplayer.PlayerMessage
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.ui.compose.PlayerSurface
import androidx.media3.ui.compose.SURFACE_TYPE_SURFACE_VIEW
import androidx.media3.ui.compose.modifiers.resizeWithContentScale
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.ConcurrentHashMap

// The Compose arm of docs/media-plan.md. The numbers below are the wire's,
// copied by hand: tools/check-verbs.py holds each against kaya.h.
internal const val PPROP_SOURCE = 1
internal const val PPROP_SPEED = 2
internal const val PPROP_VOLUME = 3
internal const val PPROP_MUTED = 4
internal const val PPROP_LOOP = 5
internal const val PPROP_CAPTIONS = 6
internal const val PLAYER_COMMAND_PLAY = 1
internal const val PLAYER_COMMAND_PAUSE = 2
internal const val PLAYER_COMMAND_SEEK = 3
internal const val SESSION_ACTION_PLAY = 1
internal const val SESSION_ACTION_PAUSE = 2
internal const val SESSION_ACTION_STOP = 3
internal const val SESSION_ACTION_SEEK_TO = 4
internal const val SESSION_ACTION_SEEK_FORWARD = 5
internal const val SESSION_ACTION_SEEK_BACKWARD = 6
internal const val SESSION_ACTION_NEXT = 7
internal const val SESSION_ACTION_PREVIOUS = 8
internal const val TRACK_KIND_AUDIO = 0
internal const val FIT_COVER = 1
internal const val FIT_FILL = 2
internal const val MEDIA_POSITION_TICK_MS = 250
internal const val MEDIA_TIMEOUT_MS = 30000

/** The players by id; the UI thread's alone. */
internal val kayaPlayers = HashMap<Long, KayaMediaPlayer>()

/** What kaya's caption renderer last drew over each video view, by node:
 * expect_caption's read (the harness thread reads it). */
internal val kayaCaptionShown = ConcurrentHashMap<Long, String>()

/** Which player each video view's surface was composed with, by node. */
internal val kayaVideoSurfaces = ConcurrentHashMap<Long, Long>()

/** Each video view's box in window pixels, clipped by its ancestors, by node. */
internal val kayaVideoBoxes = ConcurrentHashMap<Long, androidx.compose.ui.geometry.Rect>()

/** The window's view, which carries keepScreenOn (docs/media-plan.md §2 rule 5). */
internal var kayaMediaHostView: android.view.View? = null

/** A change to the user's caption style redraws every caption. */
internal val kayaCaptionStyleSeq = mutableIntStateOf(0)
private var kayaCaptionStyleWatched = false

/** One platform player: a media3 ExoPlayer the app holds by id. Every fact it
 * learns goes to the core raw, through [kayaPlayerReport]. */
internal class KayaMediaPlayer(val id: Long, context: Context) : Player.Listener {
    val exo: ExoPlayer = ExoPlayer.Builder(context, KayaRenderersFactory(context))
        // docs/media-plan.md §2 rule 6: audio focus and becoming-noisy, both on.
        .setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
            true,
        )
        .setHandleAudioBecomingNoisy(true)
        .build()

    /** Each item starts from media3's own default selection: an override is
     * keyed by a TrackGroup, and two items' groups can be equal. */
    private val defaultSelection = exo.trackSelectionParameters
    private val main = Handler(Looper.getMainLooper())
    var generation = 0
    private var loaded = false
    var mediaWidth = 0
    var mediaHeight = 0
    var speed = 1f
        private set
    private var volume = 1f
    private var muted = false

    /** onRenderedFirstFrame for this generation, and the view it was for. */
    var firstFrameGeneration = -1

    /** Seeks the core counted, whose landing it hears; a remote default's seek is not one. */
    private var seeksToReport = 0
    private var awaitingSeek = false

    /** kaya's caption renderer (docs/media-plan.md §3): the sidecar's boundaries
     * the core sent, their messages on this player's clock, and what the core
     * answered; the platform's own current cue beside it. */
    private var captionTimes: List<Long> = emptyList()
    private val captionMessages = ArrayList<PlayerMessage>()
    var kayaCaption = ""
    var platformCue = ""
    val drawsSidecar: Boolean get() = captionTimes.isNotEmpty()

    /** Whether a view of this player shows a picture: not with no item, nor
     * once the loaded item turned out to carry no video track (docs/media-plan.md §7b). */
    val showsPicture: Boolean
        get() = exo.mediaItemCount > 0 && !(loaded && !exo.currentTracks.containsType(C.TRACK_TYPE_VIDEO))

    /** An http(s) sidecar being fetched (the maintainer's ruling of 2026-09-30). */
    private var fetchGeneration = 0

    private val tick = object : Runnable {
        override fun run() {
            if (!exo.isPlaying) return
            val at = exo.currentPosition
            kayaPlayerReport(id) { KayaPresent.playerPosition(id, at) }
            main.postDelayed(this, MEDIA_POSITION_TICK_MS.toLong())
        }
    }

    init {
        exo.addListener(this)
    }

    fun release() {
        generation += 1
        fetchGeneration += 1
        main.removeCallbacksAndMessages(null)
        cancelCaptionMessages()
        exo.removeListener(this)
        exo.release()
    }

    /** A source the core resolved: an asset:///, file:// or http(s) URL, "" for none. */
    fun load(locator: String) {
        generation += 1
        val gen = generation
        loaded = false
        awaitingSeek = false
        seeksToReport = 0
        mediaWidth = 0
        mediaHeight = 0
        platformCue = ""
        kayaVideoSizeChanged(id)
        if (locator.isEmpty()) {
            exo.stop()
            exo.clearMediaItems()
            return
        }
        exo.trackSelectionParameters = defaultSelection
        exo.setMediaItem(MediaItem.fromUri(locator))
        exo.prepare()
        armCaptionMessages()
        wakeAtTheBound(gen)
    }

    /** The core's clock decides at the bound (docs/media-plan.md §7c), and a
     * player it failed `timeout` is torn down. */
    private fun wakeAtTheBound(gen: Int) {
        main.postDelayed({
            if (generation == gen) {
                var timedOut = 0
                kayaPlayerReport(id) {
                    timedOut = KayaPresent.playerOverdue(id)
                    timedOut
                }
                if (timedOut == 1) load("")
            }
        }, MEDIA_TIMEOUT_MS.toLong())
    }

    fun setVolume(v: Float) {
        volume = v
        exo.volume = if (muted) 0f else volume
    }

    fun setMuted(on: Boolean) {
        muted = on
        exo.volume = if (muted) 0f else volume
    }

    fun changeSpeed(s: Float) {
        speed = s
        exo.setPlaybackSpeed(s)
    }

    fun setLooping(on: Boolean) {
        exo.repeatMode = if (on) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    fun play() = exo.play()

    fun pause() = exo.pause()

    fun seek(ms: Long, report: Boolean) {
        wakeAtTheBound(generation)
        if (report) seeksToReport += 1
        awaitingSeek = true
        exo.seekTo(ms)
    }

    override fun onPlaybackStateChanged(state: Int) {
        when (state) {
            Player.STATE_READY -> {
                if (!loaded) {
                    loaded = true
                    reportLoaded()
                    reportTracks()
                    askCaption(0)
                }
                seekLanded()
            }
            Player.STATE_ENDED -> {
                seekLanded()
                if (loaded) {
                    askCaption(exo.duration.coerceAtLeast(0))
                    kayaPlayerReport(id) { KayaPresent.playerEnded(id) }
                }
            }
        }
    }

    private fun seekLanded() {
        if (!awaitingSeek) return
        awaitingSeek = false
        val at = exo.currentPosition
        askCaption(at)
        if (seeksToReport > 0) {
            seeksToReport -= 1
            kayaPlayerReport(id) { KayaPresent.playerSeeked(id, at) }
        }
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        kayaPlayerReport(id) { KayaPresent.playerRate(id, isPlaying) }
        main.removeCallbacks(tick)
        if (isPlaying) {
            main.post(tick)
        } else if (loaded) {
            val at = exo.currentPosition
            kayaPlayerReport(id) { KayaPresent.playerPosition(id, at) }
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        var underlying = 0L
        var cause: Throwable? = error.cause
        while (cause != null && underlying == 0L) {
            when (cause) {
                is HttpDataSource.InvalidResponseCodeException -> underlying = cause.responseCode.toLong()
                is android.media.MediaCodec.CodecException -> underlying = cause.errorCode.toLong()
            }
            cause = cause.cause
        }
        val detail = listOfNotNull(error.errorCodeName, error.message, error.cause?.message).joinToString(": ")
        android.util.Log.i("kaya", "media: player $id failed media3 ${error.errorCode} underlying $underlying: $detail")
        kayaPlayerReport(id) { KayaPresent.playerFailed(id, "media3", error.errorCode.toLong(), underlying, detail) }
    }

    override fun onTracksChanged(tracks: Tracks) {
        if (loaded) reportTracks()
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.width > 0 && videoSize.height > 0) {
            mediaWidth = videoSize.width
            mediaHeight = videoSize.height
            kayaVideoSizeChanged(id)
        }
    }

    override fun onRenderedFirstFrame() {
        firstFrameGeneration = generation
        kayaVideoSizeChanged(id)
    }

    override fun onCues(cueGroup: CueGroup) {
        val text = cueGroup.cues.mapNotNull { it.text?.toString() }.joinToString("\n")
        if (text == platformCue) return
        platformCue = text
        kayaPlayerReport(id) { KayaPresent.playerCue(id, text) }
        kayaVideoSizeChanged(id)
    }

    /**
     * THE DECODABILITY CHECK (docs/media-plan.md §7a): media3 plays the rest of
     * an item whose video or audio group has no track a decoder here supports,
     * so every such group is asked, and the core reads one as
     * failed(unsupported_codec).
     */
    private fun reportLoaded() {
        var why = ""
        for (group in exo.currentTracks.groups) {
            val kind = when (group.type) {
                C.TRACK_TYPE_VIDEO -> "video"
                C.TRACK_TYPE_AUDIO -> "audio"
                else -> continue
            }
            if (!group.isSupported) {
                val f = group.getTrackFormat(0)
                why = "the $kind track (${f.codecs ?: f.sampleMimeType}) has no decoder on this platform"
                break
            }
        }
        if (mediaWidth == 0) {
            exo.currentTracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected }?.let { g ->
                val f = (0 until g.length).firstOrNull { g.isTrackSelected(it) }?.let { g.getTrackFormat(it) }
                    ?: g.getTrackFormat(0)
                if (f.width > 0 && f.height > 0) {
                    mediaWidth = f.width
                    mediaHeight = f.height
                }
            }
        }
        kayaVideoSizeChanged(id)
        val duration = exo.duration.let { if (it == C.TIME_UNSET) 0L else it }
        kayaPlayerReport(id) {
            KayaPresent.playerLoaded(id, duration, mediaWidth, mediaHeight, why.isNotEmpty(), why)
        }
    }

    /** THE LISTING (docs/media-plan.md §3): each audio and text group as a
     * BCP 47 tag in media3's order, and which is selected. */
    fun reportTracks() {
        val groups = exo.currentTracks.groups
        val audio = groups.filter { it.type == C.TRACK_TYPE_AUDIO }
        val text = groups.filter { it.type == C.TRACK_TYPE_TEXT }
        val a = audio.joinToString("\n") { kayaLanguageTag(it.getTrackFormat(0).language) }
        val c = text.joinToString("\n") { kayaLanguageTag(it.getTrackFormat(0).language) }
        val aPick = audio.indexOfFirst { it.isSelected } + 1
        val cPick = text.indexOfFirst { it.isSelected } + 1
        kayaPlayerReport(id) { KayaPresent.playerTracks(id, a, c, aPick, cPick) }
    }

    /** select_track: media3's own group, from 1; 0 turns its captions off. */
    fun select(kind: Int, index: Int) {
        val type = if (kind == TRACK_KIND_AUDIO) C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
        val groups = exo.currentTracks.groups.filter { it.type == type }
        val params = exo.trackSelectionParameters.buildUpon()
        if (index == 0) {
            params.clearOverridesOfType(type).setTrackTypeDisabled(type, true)
        } else if (index <= groups.size) {
            params.setTrackTypeDisabled(type, false)
                .setOverrideForType(TrackSelectionOverride(groups[index - 1].mediaTrackGroup, 0))
        }
        exo.trackSelectionParameters = params.build()
    }

    /** The sidecar's boundaries, on this player's own clock: a message at each. */
    fun setCaptionTimes(times: List<Long>) {
        captionTimes = times
        armCaptionMessages()
        askCaption(0)
    }

    private fun cancelCaptionMessages() {
        for (m in captionMessages) m.cancel()
        captionMessages.clear()
    }

    private fun armCaptionMessages() {
        cancelCaptionMessages()
        if (exo.mediaItemCount == 0) return
        for (t in captionTimes) {
            captionMessages.add(
                exo.createMessage { _, _ -> askCaption(t) }
                    .setLooper(Looper.getMainLooper())
                    .setPosition(t)
                    .setDeleteAfterDelivery(false)
                    .send(),
            )
        }
    }

    /** The core answers what kaya draws at the clock's time; a boundary's
     * message is delivered once the clock has reached it. */
    fun askCaption(atLeast: Long) {
        val text = if (captionTimes.isEmpty()) "" else KayaPresent.captionAt(id, maxOf(exo.currentPosition, atLeast))
        if (text == kayaCaption) return
        kayaCaption = text
        kayaVideoSizeChanged(id)
    }

    /** An http(s) sidecar, fetched through media3's own DataSource, the stack
     * the player streams with; the TEXT goes back to the core, which parses
     * and times it. "" cancels a fetch still pending. */
    fun fetchCaptions(url: String) {
        fetchGeneration += 1
        val gen = fetchGeneration
        if (url.isEmpty()) return
        Thread({
            var text: String? = null
            var domain = "media3"
            var code = PlaybackException.ERROR_CODE_IO_UNSPECIFIED.toLong()
            var detail = ""
            val source = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true).createDataSource()
            try {
                source.open(DataSpec(Uri.parse(url)))
                text = String(DataSourceUtil.readToEnd(source), Charsets.UTF_8)
            } catch (e: HttpDataSource.InvalidResponseCodeException) {
                domain = "http"
                code = e.responseCode.toLong()
                detail = e.message ?: ""
            } catch (e: HttpDataSource.HttpDataSourceException) {
                code = e.reason.toLong()
                detail = e.message ?: ""
            } catch (e: java.io.IOException) {
                detail = e.toString()
            } finally {
                runCatching { source.close() }
                    .onFailure { android.util.Log.w("kaya", "media: closing $url: $it") }
            }
            main.post {
                if (gen != fetchGeneration) return@post
                val got = text
                if (got != null) {
                    kayaPlayerReport(id) { KayaPresent.playerCaptionsText(id, url, got) }
                } else {
                    android.util.Log.i("kaya", "media: player $id captions $url failed $domain $code: $detail")
                    kayaPlayerReport(id) { KayaPresent.playerCaptionsFailed(id, url, domain, code, 0L, detail) }
                }
            }
        }, "kaya-captions-fetch").start()
    }
}

/** media3's renderers with a decoder never moved between surfaces (docs/traps.md, the media feed entry). */
private class KayaRenderersFactory(context: Context) : DefaultRenderersFactory(context) {
    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: java.util.ArrayList<Renderer>,
    ) {
        val builder = MediaCodecVideoRenderer.Builder(context)
            .setCodecAdapterFactory(codecAdapterFactory)
            .setMediaCodecSelector(mediaCodecSelector)
            .setAllowedJoiningTimeMs(allowedVideoJoiningTimeMs)
            .setEnableDecoderFallback(enableDecoderFallback)
            .setEventHandler(eventHandler)
            .setEventListener(eventListener)
            .setMaxDroppedFramesToNotify(MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY)
        out.add(object : MediaCodecVideoRenderer(builder) {
            override fun codecNeedsSetOutputSurfaceWorkaround(name: String): Boolean = true
        })
    }
}

/** A language as BCP 47 through the platform's own canonicalizer; "und" for none. */
internal fun kayaLanguageTag(raw: String?): String {
    if (raw.isNullOrEmpty() || raw == "und") return "und"
    return java.util.Locale.forLanguageTag(raw).toLanguageTag().ifEmpty { "und" }
}

/**
 * THE ONE DOOR every player report takes: the core's answer, then the session
 * republishes its state and the keep-awake follows, so the system's playback
 * state moves on every transition (tools/check-verbs.py holds every
 * KayaPresent.player* call inside here).
 */
internal inline fun kayaPlayerReport(id: Long, report: () -> Int) {
    report()
    KayaMediaSession.follow(id)
    kayaFollowKeepAwake()
}

/** The video views showing [id] re-read its picture, its size and its captions. */
internal fun kayaVideoSizeChanged(id: Long) {
    for (node in KayaSceneModel.videos) {
        if (node.videoPlayer == id) node.videoSeq += 1
    }
}

/**
 * Rule 5 (docs/media-plan.md §2): the window is kept on exactly while a player
 * a video view shows is playing — keepScreenOn, which neither PlayerSurface nor
 * PlayerView sets; an audio-only player keeps nothing on.
 */
internal fun kayaFollowKeepAwake() {
    val on = KayaSceneModel.videos.any { node -> kayaPlayers[node.videoPlayer]?.exo?.isPlaying == true } ||
        kayaCaptureKeepsAwake()
    kayaMediaHostView?.let { if (it.keepScreenOn != on) it.keepScreenOn = on }
}

internal fun kayaMediaCreate(id: Long) {
    val context = KayaCompose.kayaAppContext ?: error("kaya: create_player $id before the Compose backend attached")
    kayaPlayers[id] = KayaMediaPlayer(id, context)
}

internal fun kayaMediaRelease(id: Long) {
    kayaPlayers.remove(id)?.release()
    kayaVideoSizeChanged(id)
    kayaFollowKeepAwake()
}

internal fun kayaMediaCommand(id: Long, command: Int, atMs: Long) {
    val p = kayaPlayers[id] ?: return
    when (command) {
        PLAYER_COMMAND_PLAY -> p.play()
        PLAYER_COMMAND_PAUSE -> p.pause()
        PLAYER_COMMAND_SEEK -> p.seek(atMs, report = true)
        else -> error("kaya: bad player command $command")
    }
}

// --- The video view (docs/media-plan.md §3) --------------------------------

/**
 * A media3 PlayerSurface of the SurfaceView type (never PlayerView, whose
 * controller and SubtitleView are View-only) at its picture's size, `fit`
 * through the frame's content scale, kaya's captions drawn over it, a picture
 * to an assistive reader with play and pause as its actions, and its shown
 * fraction reported as often as it moves (§7b).
 */
@Composable
internal fun KayaVideoView(node: KayaNode, a11y: Modifier, boxFill: Modifier) {
    node.videoSeq
    kayaCaptionStyleSeq.intValue
    val p = kayaPlayers[node.videoPlayer]
    val w = if (p != null && p.mediaWidth > 0) p.mediaWidth else 320
    val h = if (p != null && p.mediaHeight > 0) p.mediaHeight else 180
    val view = LocalView.current
    SideEffect { kayaMediaHostView = view }
    val sized = if (node.grow > 0 || node.fill == true) boxFill.height(h.dp) else Modifier.size(w.dp, h.dp)
    val actions = listOf(
        CustomAccessibilityAction("Play") { kayaPlayers[node.videoPlayer]?.play(); true },
        CustomAccessibilityAction("Pause") { kayaPlayers[node.videoPlayer]?.pause(); true },
    )
    Box(
        modifier = sized.clipToBounds()
            .then(a11y)
            .semantics {
                role = Role.Image
                customActions = actions
            }
            .onGloballyPositioned { c ->
                val all = c.size.width.toFloat() * c.size.height
                val shown = c.boundsInWindow()
                kayaVideoBoxes[node.id] = shown
                KayaPresent.videoVisible(node.id, if (all > 0) (shown.width * shown.height / all).toDouble() else 0.0)
            },
    ) {
        DisposableEffect(node.id) {
            onDispose {
                kayaVideoSurfaces.remove(node.id)
                kayaVideoBoxes.remove(node.id)
                kayaCaptionShown.remove(node.id)
                KayaPresent.videoVisible(node.id, 0.0)
            }
        }
        if (p != null && p.showsPicture) {
            val scale = when (node.fit.toInt()) {
                FIT_COVER -> ContentScale.Crop
                FIT_FILL -> ContentScale.FillBounds
                else -> ContentScale.Fit
            }
            PlayerSurface(
                player = p.exo,
                modifier = Modifier.fillMaxSize()
                    .resizeWithContentScale(scale, Size(w.toFloat(), h.toFloat()))
                    .clearAndSetSemantics {},
                surfaceType = SURFACE_TYPE_SURFACE_VIEW,
            )
            SideEffect { kayaVideoSurfaces[node.id] = p.id }
        } else {
            SideEffect { kayaVideoSurfaces.remove(node.id) }
        }
        if (node.videoCapture != 0L) KayaCapturePreview(node, node.fit.toInt() == FIT_COVER || node.fit.toInt() == FIT_FILL)
        val caption = when {
            p == null -> ""
            p.drawsSidecar -> p.kayaCaption
            else -> p.platformCue
        }
        KayaCaptionOverlay(node, caption, h)
    }
}

/**
 * kaya's caption renderer, the drawing half (docs/media-plan.md §3): the
 * sidecar's cue the core timed, or media3's own track's cue, in the user's
 * CaptioningManager style and font scale — media3's SubtitleView is a View,
 * so on Compose kaya draws both.
 */
@Composable
private fun androidx.compose.foundation.layout.BoxScope.KayaCaptionOverlay(node: KayaNode, text: String, heightDp: Int) {
    val context = LocalContext.current
    SideEffect {
        kayaCaptionShown[node.id] = text
        kayaWatchCaptionStyle(context)
    }
    if (text.isEmpty()) return
    val captioning = context.getSystemService(CaptioningManager::class.java)
    val style = captioning?.userStyle
    val scale = captioning?.fontScale ?: 1f
    val fg = style?.takeIf { it.hasForegroundColor() }?.let { Color(it.foregroundColor) } ?: Color.White
    val bg = style?.takeIf { it.hasBackgroundColor() }?.let { Color(it.backgroundColor) } ?: Color.Black
    val shadow = style?.takeIf { it.hasEdgeType() && it.edgeType == CaptioningManager.CaptionStyle.EDGE_TYPE_DROP_SHADOW }
        ?.let { Shadow(Color(it.edgeColor), Offset(2f, 2f), 2f) }
    val family = style?.typeface?.let { FontFamily(it) }
    val size = with(LocalDensity.current) { maxOf(11f, heightDp * 0.0533f * scale).dp.toSp() }
    Text(
        text = text,
        style = TextStyle(color = fg, fontSize = size, fontFamily = family, shadow = shadow, textAlign = TextAlign.Center),
        modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp).background(bg).padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

private fun kayaWatchCaptionStyle(context: Context) {
    if (kayaCaptionStyleWatched) return
    kayaCaptionStyleWatched = true
    context.getSystemService(CaptioningManager::class.java)?.addCaptioningChangeListener(
        object : CaptioningManager.CaptioningChangeListener() {
            override fun onUserStyleChanged(userStyle: CaptioningManager.CaptionStyle) {
                kayaCaptionStyleSeq.intValue += 1
            }

            override fun onFontScaleChanged(fontScale: Float) {
                kayaCaptionStyleSeq.intValue += 1
            }
        },
    )
}

/** expect_video_ink's tolerance on this lane (docs/traps.md, the BT.601 entry). */
internal const val KAYA_VIDEO_INK_TOLERANCE = 14

internal fun kayaVideoInkWithin(got: String, want: String): Boolean {
    fun rgb(s: String): List<Int>? {
        if (s.length != 6) return null
        val n = s.toIntOrNull(16) ?: return null
        return listOf((n shr 16) and 0xFF, (n shr 8) and 0xFF, n and 0xFF)
    }
    val g = rgb(got) ?: return false
    val w = rgb(want) ?: return false
    return g.zip(w).all { (a, b) -> kotlin.math.abs(a - b) <= KAYA_VIDEO_INK_TOLERANCE }
}

/** harness.rs's VIDEO_GROUND_OFFSET, in dp: where `"none"` reads the ground beside a video view. */
internal const val KAYA_VIDEO_GROUND_OFFSET = 8f

/** The view's shown box in SCREEN pixels, "left top right bottom", then the x
 * of the ground beside it, the space the runner's screencap is in; null when
 * none of it is on screen. Main thread. */
internal fun kayaVideoScreenBox(decor: android.view.View, node: KayaNode): String? {
    val box = kayaVideoBoxes[node.id] ?: return null
    if (box.width < 1f || box.height < 1f) return null
    val corner = IntArray(2)
    decor.getLocationOnScreen(corner)
    val beside = box.right + KAYA_VIDEO_GROUND_OFFSET * decor.resources.displayMetrics.density
    return "${corner[0] + box.left.toInt()} ${corner[1] + box.top.toInt()} " +
        "${corner[0] + box.right.toInt()} ${corner[1] + box.bottom.toInt()} ${corner[0] + beside.toInt()}"
}

/**
 * The frames-arriving reading, expect_video_ink's diagnostic line beside the
 * runner's screencap: media3 rendered this item's first frame to the surface
 * the view composed with its player. Null when it did, else what was seen.
 */
internal fun kayaVideoFramesWhyNot(node: KayaNode): String? {
    val p = kayaPlayers[node.videoPlayer] ?: return "the view shows no player (player ${node.videoPlayer})"
    val surface = kayaVideoSurfaces[node.id]
    if (surface != p.id) return "the view has composed no surface for player ${p.id} (it holds ${surface ?: "none"})"
    if (p.firstFrameGeneration != p.generation) {
        val rendered = p.exo.videoDecoderCounters?.renderedOutputBufferCount ?: 0
        return "media3 rendered no first frame of this item to the surface " +
            "(state ${p.exo.playbackState}, $rendered frame(s) rendered)"
    }
    return null
}

// --- The capability query (docs/media-plan.md §8 ruling 1) -----------------

private val kayaContainers = setOf(
    "video/mp4", "video/quicktime", "video/webm", "video/x-matroska", "video/mp2t", "audio/mp4", "audio/mpeg",
    "audio/ogg", "audio/webm", "audio/flac", "audio/wav", "audio/x-wav", "audio/wave", "audio/aac",
    "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/dash+xml",
)

/** media3's extractors and modules for the container, MediaCodecList for the
 * decoder of every codec named (a codec-less container names its own). */
internal fun kayaCanPlay(mime: String, codecs: String): Boolean {
    val type = mime.trim().lowercase()
    if (type !in kayaContainers) return false
    val named = codecs.split(',').map { it.trim() }.filter { it.isNotEmpty() }
    val wanted = if (named.isNotEmpty()) {
        named.map { MimeTypes.getMediaMimeType(it) ?: return false }
    } else {
        when (type) {
            "audio/mpeg" -> listOf(MimeTypes.AUDIO_MPEG)
            "audio/flac" -> listOf(MimeTypes.AUDIO_FLAC)
            else -> emptyList()
        }
    }
    val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }
    return wanted.all { w -> decoders.any { info -> info.supportedTypes.any { it.equals(w, ignoreCase = true) } } }
}

/** THIS PLATFORM'S TABLE (docs/media-plan.md §7a, the lane tables): media3
 * plays every item of the suite on the pool, and lists every embedded caption
 * track, so neither table names anything. */
internal fun kayaMediaRefusal(item: String): String? {
    item.length
    return null
}

internal fun kayaCaptionsAbsent(item: String): Boolean {
    item.length
    return false
}

/** `{media:<item>|<text>}` and `{captions:<item>|<text>}` (harness.rs's
 * expand_media, the same grammar): null for a malformed template, with the
 * sentence in [KayaExpanded.refused]. */
internal fun kayaExpandMedia(want: String): KayaExpanded {
    var out = want
    for ((open, answer) in listOf(
        "{media:" to { item: String, text: String -> kayaMediaRefusal(item)?.let { "failed $it, can_play no" } ?: text },
        "{captions:" to { item: String, text: String -> if (kayaCaptionsAbsent(item)) "captions none" else text },
    )) {
        val b = StringBuilder()
        var rest = out
        while (true) {
            val start = rest.indexOf(open)
            if (start < 0) break
            b.append(rest, 0, start)
            val after = rest.substring(start + open.length)
            val end = after.indexOf('}')
            if (end < 0) return KayaExpanded(want, "unterminated $open…} in ${kayaDebugQuoted(want)}")
            val spec = after.substring(0, end)
            val bar = spec.indexOf('|')
            if (bar < 0) return KayaExpanded(want, "$open$spec} wants <item>|<text>")
            b.append(answer(spec.substring(0, bar), spec.substring(bar + 1)))
            rest = after.substring(end + 1)
        }
        b.append(rest)
        out = b.toString()
    }
    return KayaExpanded(out, null)
}

// --- The session (docs/media-plan.md §5) -----------------------------------

/**
 * The app's one session: a media3 MediaSession over a player whose state is
 * kaya's — kaya_session_state for the playback state, the attached player's
 * clock for the position — and whose commands the core routes. A
 * MediaSessionService posts the MediaStyle notification as a mediaPlayback
 * foreground service.
 */
internal object KayaMediaSession {
    var player = 0L
    var offered = 0
    var title = ""
    var artist = ""
    var album = ""
    var artwork = ""
    var session: MediaSession? = null
    private var statePlayer: KayaSessionPlayer? = null

    /** How many system commands reached this session: session_send's proof that
     * the system delivered (the harness thread reads it). */
    @Volatile var arrivals = 0

    fun apply(context: Context, attached: Long, actions: Int, t: String, a: String, al: String, art: String) {
        player = attached
        offered = actions
        title = t
        artist = a
        album = al
        artwork = art
        if (session == null && (player != 0L || offered != 0)) {
            val sp = KayaSessionPlayer()
            statePlayer = sp
            session = MediaSession.Builder(context, sp).setId("kaya").build()
            context.startService(Intent(context, KayaMediaService::class.java))
            KayaMediaService.running?.addSession(session!!)
        }
        statePlayer?.publish()
    }

    /** After every report of any player: the system's playback state re-read. */
    fun follow(id: Long) {
        if (id == player || player == 0L) statePlayer?.publish()
    }

    /** A command from the system: the CORE routes it (kaya_session_action),
     * and a default aimed at the attached player runs here. */
    fun remote(action: Int, atMs: Long) {
        arrivals += 1
        val route = KayaPresent.sessionAction(action, atMs)
        KayaDiag.note("media: remote action=$action at=$atMs routed $route (0 app, 1-3 and 5 the player, 4 not offered)")
        val p = kayaPlayers[player] ?: return
        when (route) {
            1 -> p.play()
            2 -> p.pause()
            3 -> p.seek(atMs, report = false)
            5 -> {
                p.seek(0, report = false)
                p.play()
            }
        }
    }

    /** expect_now_playing's read: the session as the SYSTEM holds it, through a
     * platform MediaController on its token (system_server's session record). */
    fun nowPlaying(context: Context): String {
        val token = session?.platformToken ?: return "\"\" stopped"
        val controller = android.media.session.MediaController(context, token)
        val t = controller.metadata?.getString(android.media.MediaMetadata.METADATA_KEY_TITLE) ?: ""
        val state = when (controller.playbackState?.state) {
            android.media.session.PlaybackState.STATE_PLAYING -> "playing"
            android.media.session.PlaybackState.STATE_PAUSED -> "paused"
            else -> "stopped"
        }
        return "${kayaDebugQuoted(t)} $state"
    }
}

/** The player the session speaks for: its state is kaya's, read fresh each
 * time media3 asks, and every command it receives is a system command. */
internal class KayaSessionPlayer : SimpleBasePlayer(Looper.getMainLooper()) {
    fun publish() = invalidateState()

    override fun getState(): State {
        val s = KayaMediaSession
        val commands = Player.Commands.Builder().addAll(
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_GET_METADATA,
        )
        fun offers(action: Int) = s.offered and (1 shl action) != 0
        if (offers(SESSION_ACTION_PLAY) || offers(SESSION_ACTION_PAUSE)) commands.add(Player.COMMAND_PLAY_PAUSE)
        if (offers(SESSION_ACTION_STOP)) commands.add(Player.COMMAND_STOP)
        if (offers(SESSION_ACTION_SEEK_TO)) commands.add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
        if (offers(SESSION_ACTION_SEEK_FORWARD)) commands.add(Player.COMMAND_SEEK_FORWARD)
        if (offers(SESSION_ACTION_SEEK_BACKWARD)) commands.add(Player.COMMAND_SEEK_BACK)
        if (offers(SESSION_ACTION_NEXT)) commands.addAll(Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
        if (offers(SESSION_ACTION_PREVIOUS)) {
            commands.addAll(Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
        }
        val builder = State.Builder().setAvailableCommands(commands.build())
        if (s.player == 0L && s.offered == 0) return builder.setPlaybackState(Player.STATE_IDLE).build()
        val code = KayaPresent.sessionState()
        val p = kayaPlayers[s.player]
        val meta = MediaMetadata.Builder().setTitle(s.title).setArtist(s.artist).setAlbumTitle(s.album)
        if (s.artwork.isNotEmpty()) meta.setArtworkUri(Uri.parse(s.artwork))
        val durationMs = p?.exo?.duration?.takeIf { it != C.TIME_UNSET && it > 0 }
        val item = MediaItemData.Builder("kaya-session")
            .setMediaMetadata(meta.build())
            .setDurationUs(durationMs?.times(1000) ?: C.TIME_UNSET)
            .setIsSeekable(true)
            .build()
        return builder.setPlaylist(listOf(item))
            .setCurrentMediaItemIndex(0)
            .setPlaybackState(if (code == 0) Player.STATE_IDLE else Player.STATE_READY)
            .setPlayWhenReady(code == 1, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setContentPositionMs { kayaPlayers[KayaMediaSession.player]?.exo?.currentPosition ?: 0L }
            .setPlaybackParameters(PlaybackParameters(p?.speed ?: 1f))
            .build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        KayaMediaSession.remote(if (playWhenReady) SESSION_ACTION_PLAY else SESSION_ACTION_PAUSE, 0)
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> {
        KayaMediaSession.remote(SESSION_ACTION_STOP, 0)
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        val action = when (seekCommand) {
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> SESSION_ACTION_NEXT
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> SESSION_ACTION_PREVIOUS
            Player.COMMAND_SEEK_FORWARD -> SESSION_ACTION_SEEK_FORWARD
            Player.COMMAND_SEEK_BACK -> SESSION_ACTION_SEEK_BACKWARD
            else -> SESSION_ACTION_SEEK_TO
        }
        KayaMediaSession.remote(action, positionMs.coerceAtLeast(0))
        return Futures.immediateVoidFuture()
    }
}

/** The mediaPlayback foreground service that posts the session's MediaStyle
 * notification (docs/media-plan.md §5); the app's manifest grants its
 * permissions. */
class KayaMediaService : MediaSessionService() {
    override fun onCreate() {
        super.onCreate()
        running = this
        KayaMediaSession.session?.let { addSession(it) }
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = KayaMediaSession.session

    companion object {
        var running: KayaMediaService? = null
    }
}

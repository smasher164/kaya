package dev.kaya.videoprobe

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.AndroidEmbeddedExternalSurface
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener

/**
 * The §1.0d probe (docs/probes/video-playback-2026-09-02.md): does kaya's
 * own window-overload PixelCopy read a video back, and does the answer
 * depend on whether the player renders into a composited external texture
 * or into a SurfaceView's own layer?
 *
 * The pixel read below is KayaCompose.kt's `kayaCanvasInk` transcribed:
 * the same Compose `boundsInWindow()` box, the same decor offset and
 * intersection, the same ARGB_8888 bitmap, the same
 * `PixelCopy.request(activity.window, ...)` overload, the same hex.
 */
class ProbeActivity : ComponentActivity() {

    private val logTag = "kayavideoprobe"
    private var player: ExoPlayer? = null
    private var box: Rect? = null
    private var t0 = 0L
    private var firstFrame = -1L
    private var loops = 0
    // HELD: a Surface that goes out of scope is finalized, and its
    // native release tears the producer connection down.
    private var heldSurface: Surface? = null
    private lateinit var route: String
    private lateinit var clip: String
    // OFF BY DEFAULT: getBitmap() reads the layer back and is itself
    // suspected of moving what the window copy then sees.
    private var tvread = false
    // Ask the window to redraw and let two frames pass before the
    // copy: the emulator draws this app ~1.7 times a second, so a
    // copy of "the window as it stands" can predate every frame the
    // player has produced.
    private var nudge = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        t0 = SystemClock.elapsedRealtime()
        route = intent.getStringExtra("route") ?: "texture"
        clip = intent.getStringExtra("clip") ?: "flat_h264.mp4"
        tvread = intent.getStringExtra("tvread") == "1"
        nudge = intent.getStringExtra("nudge") == "1"
        Log.i(logTag, "START route=$route clip=$clip sdk=${android.os.Build.VERSION.SDK_INT} " +
            "device=${android.os.Build.DEVICE} fingerprint=${android.os.Build.FINGERPRINT}")

        val p = ExoPlayer.Builder(this).build()
        player = p
        p.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() {
                if (firstFrame < 0) {
                    firstFrame = SystemClock.elapsedRealtime() - t0
                    Log.i(logTag, "FIRSTFRAME route=$route at ${firstFrame}ms after onCreate")
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e(logTag, "PLAYERERROR route=$route ${error.errorCodeName}: ${error.message}")
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                if (reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION) {
                    loops += 1
                    Log.i(logTag, "LOOP route=$route n=$loops at " +
                        "${SystemClock.elapsedRealtime() - t0}ms")
                }
            }

            override fun onPlaybackStateChanged(state: Int) {
                Log.i(logTag, "STATE route=$route state=$state at " +
                    "${SystemClock.elapsedRealtime() - t0}ms")
            }
        })
        p.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) {
                Log.i(logTag, "DECODER route=$route name=$decoderName " +
                    "init=${initializationDurationMs}ms")
            }
        })
        p.setMediaItem(MediaItem.fromUri("asset:///$clip"))
        p.repeatMode = Player.REPEAT_MODE_ALL
        p.playWhenReady = true
        p.prepare()

        setContent {
            // MAGENTA BEHIND THE VIDEO, deliberately: three outcomes are
            // then distinguishable in one hex — the clip's own 2C3B4F, the
            // window content behind a punched hole (FF00FF), and a cleared
            // hole (000000).
            Column(Modifier.fillMaxSize().background(Color(0xFFFF00FF))) {
                Box(
                    Modifier
                        .padding(16.dp)
                        .size(288.dp, 216.dp)
                        .background(Color(0xFFFF00FF))
                        .onGloballyPositioned {
                            val r = it.boundsInWindow()
                            box = Rect(
                                r.left.toInt(), r.top.toInt(),
                                r.right.toInt(), r.bottom.toInt())
                        }
                ) {
                    VideoSurface(route)
                }
            }
        }

        val h = Handler(Looper.getMainLooper())
        // DENSE, because the first round found the window copy answering
        // the video ONCE and black the next time on the SAME route: a
        // race is only measurable as a rate.
        val schedule = if (intent.getStringExtra("cadence") == "sparse") {
            // What kaya's harness actually does: one expect_ink per step.
            longArrayOf(1200, 2000, 3500, 5000, 8000, 12000, 16000)
        } else {
            var at = 800L
            val out = ArrayList<Long>()
            while (at <= 16000L) { out.add(at); at += 400L }
            out.toLongArray()
        }
        for (whenMs in schedule) {
            h.postDelayed({ sample(whenMs) }, whenMs)
        }
        h.postDelayed({
            Log.i(logTag, "DONE route=$route clip=$clip firstFrame=${firstFrame}ms loops=$loops")
            finish()
        }, 17000)
    }

    @Composable
    private fun VideoSurface(route: String) {
        val p = player ?: return
        when (route) {
            // The Compose-idiomatic external texture: a TextureView under
            // the hood, composited into the window like any other view.
            "embedded" -> AndroidEmbeddedExternalSurface(Modifier.fillMaxSize()) {
                onSurface { surface, _, _ ->
                    Log.i(logTag, "SURFACE route=embedded AndroidEmbeddedExternalSurface")
                    p.setVideoSurface(surface)
                }
            }
            // The same thing spelled by hand, so the reading cannot be an
            // artifact of the Compose wrapper.
            "texture" -> AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    TextureView(ctx).apply {
                        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(
                                st: android.graphics.SurfaceTexture, w: Int, h: Int,
                            ) {
                                Log.i(logTag, "SURFACE route=texture TextureView ${w}x$h")
                                heldSurface = Surface(st)
                                p.setVideoSurface(heldSurface)
                            }

                            override fun onSurfaceTextureSizeChanged(
                                st: android.graphics.SurfaceTexture, w: Int, h: Int,
                            ) = Unit

                            override fun onSurfaceTextureDestroyed(
                                st: android.graphics.SurfaceTexture,
                            ): Boolean = true

                            override fun onSurfaceTextureUpdated(
                                st: android.graphics.SurfaceTexture,
                            ) = Unit
                        }
                    }
                },
            )
            // THE CONTROL: a hole punched in the window, composited by
            // SurfaceFlinger as its own layer.
            else -> AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    SurfaceView(ctx).apply {
                        holder.addCallback(object : SurfaceHolder.Callback {
                            override fun surfaceCreated(holder: SurfaceHolder) {
                                Log.i(logTag, "SURFACE route=surfaceview SurfaceView")
                                p.setVideoSurface(holder.surface)
                            }

                            override fun surfaceChanged(
                                holder: SurfaceHolder, format: Int, w: Int, h: Int,
                            ) = Unit

                            override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
                        })
                    }
                },
            )
        }
    }

    private var dumped = false
    private var tv: TextureView? = null

    /** What the route actually put in the view tree, so "external texture"
     * and "SurfaceView" are read off the device rather than assumed. */
    private fun dumpTree() {
        if (dumped) return
        dumped = true
        fun walk(v: android.view.View, depth: Int) {
            val extra = when (v) {
                is TextureView -> { tv = v; " [TextureView opaque=${v.isOpaque} " +
                    "available=${v.isAvailable} layer=${v.layerType}]" }
                is SurfaceView -> " [SurfaceView zOrderOnTop=? " +
                    "holderSurfaceValid=${v.holder.surface?.isValid}]"
                else -> ""
            }
            Log.i(logTag, "TREE route=$route " + " ".repeat(depth) +
                "${v.javaClass.name} ${v.width}x${v.height}$extra")
            if (v is android.view.ViewGroup) {
                for (i in 0 until v.childCount) walk(v.getChildAt(i), depth + 1)
            }
        }
        walk(window.decorView, 0)
    }

    /** KayaCompose.kt:4024 `kayaCanvasInk`, transcribed. */
    private fun sample(at: Long) {
        dumpTree()
        if (nudge) {
            tv?.invalidate()
            window.decorView.invalidate()
            android.view.Choreographer.getInstance().postFrameCallback {
                Handler(Looper.getMainLooper()).postDelayed({ copy(at) }, 64)
            }
        } else {
            copy(at)
        }
    }

    private fun copy(at: Long) {
        val p = player
        val b = box
        if (b == null) {
            Log.w(logTag, "INK route=$route at=${at}ms <no box: the video has not been laid out>")
            return
        }
        val decor = window.decorView
        val loc = IntArray(2)
        decor.getLocationInWindow(loc)
        val src = Rect(b)
        src.offset(loc[0], loc[1])
        if (!src.intersect(0, 0, decor.width, decor.height)) {
            Log.w(logTag, "INK route=$route at=${at}ms <the box sits outside the window's " +
                "own surface: $src of ${decor.width}x${decor.height}>")
            return
        }
        val bitmap = Bitmap.createBitmap(src.width(), src.height(), Bitmap.Config.ARGB_8888)
        // kaya's own copy blocks on a latch because it runs on the harness
        // thread; this one is ON the main thread, which is the callback's
        // thread too, so the read finishes in the callback or never.
        PixelCopy.request(
            window,
            src,
            bitmap,
            { code ->
                if (code != PixelCopy.SUCCESS) {
                    Log.w(logTag, "INK route=$route at=${at}ms " +
                        "<PixelCopy answered $code for $src>")
                    bitmap.recycle()
                } else {
                    val samples = listOf(50.0 to 50.0, 10.0 to 10.0, 90.0 to 90.0)
                        .joinToString("/") { (px, py) ->
                            val x = ((bitmap.width * px / 100.0).toInt())
                                .coerceIn(0, bitmap.width - 1)
                            val y = ((bitmap.height * py / 100.0).toInt())
                                .coerceIn(0, bitmap.height - 1)
                            val pixel = bitmap.getPixel(x, y)
                            String.format(
                                "%02X%02X%02X",
                                (pixel shr 16) and 0xFF,
                                (pixel shr 8) and 0xFF,
                                pixel and 0xFF,
                            )
                        }
                    val centre = bitmap.getPixel(bitmap.width / 2, bitmap.height / 2)
                    // The SECOND reading: TextureView's own getBitmap, which
                    // does not go through the window at all.
                    val tvHex = (if (tvread) tv else null)?.let { view ->
                        val b2 = view.getBitmap(8, 8)
                        val hex = if (b2 == null) "<null>" else String.format(
                            "%02X%02X%02X",
                            (b2.getPixel(4, 4) shr 16) and 0xFF,
                            (b2.getPixel(4, 4) shr 8) and 0xFF,
                            b2.getPixel(4, 4) and 0xFF)
                        b2?.recycle()
                        hex
                    } ?: "<off>"
                    Log.i(logTag, "INK route=$route clip=$clip at=${at}ms rect=$src " +
                        "ink=$samples alpha=${(centre ushr 24) and 0xFF} tvink=$tvHex " +
                        "state=${p?.playbackState} pos=${p?.currentPosition} " +
                        "playing=${p?.isPlaying} loops=$loops")
                    bitmap.recycle()
                }
            },
            Handler(Looper.getMainLooper()),
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        player?.release()
        player = null
    }
}

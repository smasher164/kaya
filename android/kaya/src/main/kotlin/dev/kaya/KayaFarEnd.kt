package dev.kaya

import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.audiofx.AcousticEchoCanceler
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import java.nio.ByteBuffer

// The far end of a call (docs/capture-plan.md §5): the surface the app's
// frames are shown on and the voice output its samples play through.

/** KAYA_VOICE_ROUTE_* (tools/check-verbs.py holds them against the spec's). */
internal const val VOICE_ROUTE_VOICE = 1
internal const val VOICE_ROUTE_FAILED = 4

/** A surface's last frame shown: its number, its bitmap, and its shape. */
private class KayaSurfaceShown {
    var seen = 0L
    var bitmap: Bitmap? = null
    val shape = LongArray(4)
}

/**
 * A surface: the app's last frame, stood upright as RGBA by the core, drawn
 * as an image at the self-view's box (docs/capture-plan.md §3) and taken on
 * Compose's frame clock; the image keeps it.
 */
@Composable
internal fun KayaSurfaceView(node: KayaNode, a11y: Modifier, boxFill: Modifier) {
    node.videoSeq
    val shown = remember(node.id) { KayaSurfaceShown() }
    val picture = remember(node.id) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    val box = KayaPresent.captureSelfViewBox(
        shown.shape[0].toInt(), shown.shape[1].toInt(), shown.shape[2].toInt(), node.aspect,
    ) ?: error("kaya: captureSelfViewBox answered nothing")
    val w = box[0]
    val h = box[1]
    LaunchedEffect(node.id) {
        while (true) {
            withFrameNanos { }
            val shape = LongArray(4)
            val rgba = KayaPresent.surfaceTake(node.id, shown.seen, shape) ?: continue
            val uw = (if (shape[2] % 180 == 90L) shape[1] else shape[0]).toInt()
            val uh = (if (shape[2] % 180 == 90L) shape[0] else shape[1]).toInt()
            val bitmap = shown.bitmap?.takeIf { it.width == uw && it.height == uh }
                ?: Bitmap.createBitmap(uw, uh, Bitmap.Config.ARGB_8888)
            bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
            shown.bitmap = bitmap
            shown.seen = shape[3]
            val reshaped = !(shown.shape[0] == shape[0] && shown.shape[1] == shape[1] && shown.shape[2] == shape[2])
            shape.copyInto(shown.shape)
            picture.value = bitmap.asImageBitmap()
            if (reshaped) node.videoSeq += 1
        }
    }
    val sized = when {
        node.grow > 0 || node.fill == true -> boxFill.aspectRatio(w.toFloat() / h)
        else -> Modifier.widthIn(max = w.dp).fillMaxWidth().aspectRatio(w.toFloat() / h)
    }
    Box(
        modifier = sized.then(kayaBleed(node)).clipToBounds()
            .then(a11y)
            .semantics { role = Role.Image }
            .onGloballyPositioned { c ->
                kayaVideoBoxes[node.id] = c.boundsInWindow()
                kayaVideoFrames[node.id] = androidx.compose.ui.geometry.Rect(
                    c.positionInWindow(),
                    androidx.compose.ui.geometry.Size(c.size.width.toFloat(), c.size.height.toFloat()),
                )
            },
    ) {
        DisposableEffect(node.id) {
            onDispose {
                kayaVideoBoxes.remove(node.id)
                kayaVideoFrames.remove(node.id)
            }
        }
        picture.value?.let {
            Image(
                bitmap = it,
                contentDescription = null,
                contentScale = when (node.fit.toInt()) {
                    FIT_COVER -> ContentScale.Crop
                    FIT_FILL -> ContentScale.FillBounds
                    else -> ContentScale.Fit
                },
                modifier = Modifier.fillMaxSize().clearAndSetSemantics {},
            )
        }
    }
}

/** expect_video_ink's diagnostic line for a surface: the core's account. */
internal fun kayaSurfaceAccount(node: KayaNode): String {
    return KayaPresent.surfaceDetail(node.id)
}

/** Every live voice output by id. */
internal val kayaVoices = HashMap<Long, KayaVoiceOutput>()

/**
 * A voice output: an AudioTrack marked USAGE_VOICE_COMMUNICATION, the path
 * Android's echo canceller takes as the far end, written on a thread of its
 * own from the core's queue; a blocking write paces it at the track's rate.
 */
internal class KayaVoiceOutput(val id: Long) {
    private val rate = 48_000
    private val chunk = 480
    @Volatile private var running = true
    private var track: AudioTrack? = null

    init {
        try {
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
            val t = AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minimum, chunk * 4 * 4))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            track = t
            t.play()
            KayaPresent.voiceRoute(
                id, VOICE_ROUTE_VOICE,
                "AudioTrack, USAGE_VOICE_COMMUNICATION, 48000 Hz mono float, session ${t.audioSessionId}, " +
                    "AcousticEchoCanceler ${if (AcousticEchoCanceler.isAvailable()) "available" else "not available"}",
            )
            Thread({ pump(t) }, "kaya voice $id").start()
        } catch (e: Exception) {
            KayaPresent.voiceRoute(id, VOICE_ROUTE_FAILED, "the AudioTrack would not open: $e")
        }
    }

    private fun pump(t: AudioTrack) {
        val buffer = FloatArray(chunk)
        while (running) {
            KayaPresent.voicePull(id, rate, 1, buffer, chunk)
            if (t.write(buffer, 0, chunk, AudioTrack.WRITE_BLOCKING) < 0) break
        }
    }

    fun release() {
        running = false
        track?.let {
            it.pause()
            it.flush()
            it.release()
        }
        track = null
    }
}

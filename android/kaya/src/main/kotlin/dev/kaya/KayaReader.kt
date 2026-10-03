package dev.kaya

import android.content.Context
import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaDataSource
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import java.io.FileNotFoundException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * THE READER (docs/media-plan.md §8 ruling 4): a thread per read. The video
 * track's sample times come from MediaExtractor first, so a frame's ACTUAL
 * time is the platform's own and `keyframe` is the sync sample at or before
 * (the retriever reports no time); MediaMetadataRetriever then decodes that
 * one picture. PCM comes from MediaExtractor + MediaCodec, 16-bit read as
 * v/32768 so a 16-bit file reaches the core sample for sample. Every report
 * reaches the core on the main thread, the ring's one producer.
 */
internal val kayaReaders = HashMap<Long, KayaReader>()

/** The domain a reader's platform failure is reported under, and its codes:
 * kaya's names for the exception each platform call threw (the core's
 * failure table reads them, crate::media::failure_reason). */
internal const val READER_DOMAIN = "android.reader"
internal const val READER_UNREADABLE = 1L
internal const val READER_MISSING = 2L
internal const val READER_NO_DECODER = 3L
internal const val READER_DECODE = 4L
internal const val READER_NO_PICTURE = 5L

private class ReaderFlight {
    private val stopped = AtomicBoolean(false)
    val room = Semaphore(4)
    val wanted get() = !stopped.get()
    fun stop() {
        stopped.set(true)
        room.release(64)
    }
}

internal class KayaReader(private val id: Long, private val url: String) {
    private val main = Handler(Looper.getMainLooper())
    /** The read in flight, 0 for none; a report for any other is dropped. */
    private var read = 0L
    private var flight: ReaderFlight? = null
    /** Bumped at every answer, so only the latest bound timer asks. */
    private var answers = 0

    /** The bound (docs/media-plan.md §7c) from the ask or the latest answer:
     * the core's clock decides, and a read it failed `timeout` is stopped. */
    private fun answered(read: Long) {
        answers += 1
        val seen = answers
        main.postDelayed({
            if (this.read == read && answers == seen && KayaPresent.readerOverdue(id, read) == 1) stop(read)
        }, MEDIA_TIMEOUT_MS.toLong())
    }

    fun stop(read: Long) {
        if (this.read != read || read == 0L) return
        this.read = 0
        flight?.stop()
        flight = null
    }

    fun close() = stop(read)

    private fun start(read: Long, work: (ReaderFlight) -> Unit) {
        val f = ReaderFlight()
        this.read = read
        flight = f
        answered(read)
        Thread({
            try {
                work(f)
            } catch (e: Throwable) {
                failed(f, read, READER_DECODE, "kaya: the reader's platform work threw $e")
            }
        }, "kaya-reader-$id").start()
    }

    private fun onMain(f: ReaderFlight, body: () -> Unit) {
        main.post { if (f.wanted) body() }
        Unit
    }

    private fun failed(f: ReaderFlight, read: Long, code: Long, detail: String) = onMain(f) {
        if (this.read != read) return@onMain
        KayaPresent.readerFailed(id, read, READER_DOMAIN, code, 0, detail)
        stop(read)
    }

    /** THE ONE SITE a read for a track the source lacks is reported from;
     * the core decides its reason, no_track (docs/media-plan.md §8 ruling 4). */
    private fun noTrack(f: ReaderFlight, read: Long, kind: String) = onMain(f) {
        if (this.read != read) return@onMain
        KayaPresent.readerNoTrack(id, read, "kaya: the source has no $kind track")
        stop(read)
    }

    private fun finished(f: ReaderFlight, read: Long) = onMain(f) {
        if (this.read != read) return@onMain
        KayaPresent.readerFinished(id, read)
        stop(read)
    }

    private fun context(): Context = KayaCompose.kayaAppContext ?: error("kaya: a reader before the Compose backend attached")

    /** The source as the platform's two readers take it: an APK asset by
     * its descriptor when stored uncompressed, else its bytes. */
    private fun open(extractor: MediaExtractor?, retriever: MediaMetadataRetriever?) {
        val uri = Uri.parse(url)
        when (uri.scheme) {
            "asset" -> {
                val name = uri.path!!.removePrefix("/")
                try {
                    context().assets.openFd(name).use { fd ->
                        extractor?.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                        retriever?.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                    }
                } catch (e: FileNotFoundException) {
                    val bytes = context().assets.open(name).use { it.readBytes() }
                    extractor?.setDataSource(BytesSource(bytes))
                    retriever?.setDataSource(BytesSource(bytes))
                }
            }
            "http", "https" -> {
                extractor?.setDataSource(url, emptyMap())
                retriever?.setDataSource(url, emptyMap())
            }
            else -> {
                extractor?.setDataSource(context(), uri, null)
                retriever?.setDataSource(context(), uri)
            }
        }
    }

    /** The first `prefix` track's index, or -1. */
    private fun track(extractor: MediaExtractor, prefix: String): Int =
        (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith(prefix) == true
        } ?: -1

    /** Opens the extractor, reporting the platform's refusal; null when it refused. */
    private fun opened(f: ReaderFlight, read: Long, extractor: MediaExtractor, retriever: MediaMetadataRetriever?): Boolean =
        try {
            open(extractor, retriever)
            true
        } catch (e: FileNotFoundException) {
            failed(f, read, READER_MISSING, "kaya: $url: $e")
            false
        } catch (e: Exception) {
            failed(f, read, READER_UNREADABLE, "kaya: the platform would not read $url: $e")
            false
        }

    fun frames(read: Long, exact: Boolean, maxW: Int, maxH: Int, times: LongArray) = start(read) { f ->
        val extractor = MediaExtractor()
        val retriever = MediaMetadataRetriever()
        try {
            if (!opened(f, read, extractor, retriever)) return@start
            val video = track(extractor, "video/")
            if (video < 0) return@start noTrack(f, read, "video")
            extractor.selectTrack(video)
            val all = ArrayList<Long>()
            val sync = ArrayList<Long>()
            while (f.wanted) {
                val t = extractor.sampleTime
                if (t < 0) break
                all.add(t)
                if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) sync.add(t)
                if (!extractor.advance()) break
            }
            all.sort()
            sync.sort()
            if (all.isEmpty()) return@start finished(f, read)
            for ((index, ms) in times.withIndex()) {
                if (!f.wanted) return@start
                // Half a millisecond either side of a picture's own time.
                val at = atOrBefore(if (exact) all else sync.ifEmpty { all }, ms * 1000 + 500)
                val option = if (exact) MediaMetadataRetriever.OPTION_CLOSEST else MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                val bitmap = retriever.getFrameAtTime(at, option)
                    ?: return@start failed(f, read, READER_NO_PICTURE, "kaya: the platform gave no picture at ${at / 1000} ms")
                val rgba = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
                val bytes = ByteBuffer.allocate(rgba.byteCount)
                rgba.copyPixelsToBuffer(bytes)
                val (w, h) = rgba.width to rgba.height
                val actualMs = (at + 500) / 1000
                onMain(f) {
                    if (this.read != read) return@onMain
                    val live = KayaPresent.readerFrame(id, read, index, actualMs, w, h, maxW, maxH, bytes.array())
                    if (live == 0) stop(read) else answered(read)
                }
            }
        } finally {
            extractor.release()
            retriever.release()
        }
    }

    private fun atOrBefore(sorted: List<Long>, us: Long): Long {
        var found = sorted.first()
        for (t in sorted) {
            if (t > us) break
            found = t
        }
        return found
    }

    fun peaks(read: Long) = start(read) { f ->
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            if (!opened(f, read, extractor, null)) return@start
            val audio = track(extractor, "audio/")
            if (audio < 0) return@start noTrack(f, read, "audio")
            extractor.selectTrack(audio)
            val format = extractor.getTrackFormat(audio)
            val totalMs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) / 1000 else 0L
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            codec = try {
                MediaCodec.createDecoderByType(mime)
            } catch (e: Exception) {
                return@start failed(f, read, READER_NO_DECODER, "kaya: no decoder for $mime: $e")
            }
            codec.configure(format, null, null, 0)
            codec.start()
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var float = false
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            while (f.wanted) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val n = extractor.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val out = codec.outputFormat
                    channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    rate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    float = out.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        out.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (o >= 0) {
                    val buffer = codec.getOutputBuffer(o)!!.order(ByteOrder.LITTLE_ENDIAN)
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val samples = if (float) {
                        FloatArray(info.size / 4).also { buffer.asFloatBuffer().get(it) }
                    } else {
                        val s = buffer.asShortBuffer()
                        FloatArray(info.size / 2) { s.get(it) / 32768f }
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (samples.isNotEmpty()) {
                        while (f.wanted && !f.room.tryAcquire(100, TimeUnit.MILLISECONDS)) {}
                        if (!f.wanted) return@start
                        val (c, r) = channels to rate
                        onMain(f) {
                            f.room.release()
                            if (this.read != read) return@onMain
                            val live = KayaPresent.readerPcm(id, read, c, r, samples, totalMs)
                            if (live == 0) stop(read) else answered(read)
                        }
                    }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return@start finished(f, read)
                }
            }
        } catch (e: MediaCodec.CodecException) {
            failed(f, read, READER_DECODE, "kaya: the decoder failed: ${e.diagnosticInfo}")
        } finally {
            try {
                codec?.stop()
            } catch (_: IllegalStateException) {
            }
            codec?.release()
            extractor.release()
        }
    }
}

/** An APK asset stored compressed, read whole: MediaExtractor and the
 * retriever then read it from memory. */
private class BytesSource(private val bytes: ByteArray) : MediaDataSource() {
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position >= bytes.size) return -1
        val n = minOf(size.toLong(), bytes.size - position).toInt()
        System.arraycopy(bytes, position.toInt(), buffer, offset, n)
        return n
    }

    override fun getSize(): Long = bytes.size.toLong()

    override fun close() {}
}

internal fun kayaReaderOpen(reader: Long, url: String) {
    kayaReaders[reader] = KayaReader(reader, url)
}

internal fun kayaReaderClose(reader: Long) {
    kayaReaders.remove(reader)?.close()
}

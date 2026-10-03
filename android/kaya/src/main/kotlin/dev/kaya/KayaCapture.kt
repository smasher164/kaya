package dev.kaya

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.graphics.ImageFormat
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// The capture's wire numbers (docs/capture-plan.md; tools/check-verbs.py
// holds them against the spec's).
internal const val CAPTURE_STATE_RUNNING = 2
internal const val CAPTURE_STATE_FAILED = 4
internal const val CAPTURE_FAILURE_DENIED = 1
internal const val CAPTURE_FAILURE_NOT_FOUND = 2
internal const val CAPTURE_FAILURE_IN_USE = 3
internal const val CAPTURE_FAILURE_DISCONNECTED = 4
internal const val CAPTURE_FAILURE_UNSUPPORTED = 5
internal const val CAPTURE_FAILURE_HARDWARE_ERROR = 6
internal const val CAPTURE_KIND_CAMERA = 0
internal const val CAPTURE_KIND_MICROPHONE = 1
internal const val PERMISSION_PROMPT = 0
internal const val PERMISSION_GRANTED = 1
internal const val PERMISSION_DENIED = 2
internal const val CAMERA_FACING_UNKNOWN = 0
internal const val CAMERA_FACING_FRONT = 1
internal const val CAMERA_FACING_BACK = 2
internal const val CAMERA_FACING_EXTERNAL = 3
internal const val CAPTURE_COMMAND_START = 1
internal const val CPROP_CAMERA = 1
internal const val CPROP_MICROPHONE = 2
internal const val CPROP_WIDTH = 3
internal const val CPROP_HEIGHT = 4
internal const val CPROP_FRAME_RATE = 5
internal const val CPROP_MUTED = 6

/** Every live capture by id; the app thread's (main) alone. */
internal val kayaCaptures = HashMap<Long, KayaCapture>()
private val kayaCaptureMain = Handler(Looper.getMainLooper())
private var kayaCaptureWatching = false

/** Whether this process runs under the harness: then the devices are the
 * lane's (docs/capture-plan.md §7, THE WALL). Read per call, since the
 * KAYA_* extras reach the environment per scene (KayaEnv). */
internal fun kayaCaptureUnderHarness(): Boolean = System.getenv("KAYA_SELFTEST") != null

/** One device as this backend lists it. */
internal class KayaCaptureDeviceInfo(
    val id: String,
    val name: String,
    val kind: Int,
    val facing: Int,
    val preferred: Boolean,
    /** A synthetic device's colour or tone; 0 for a real one. */
    val content: Int,
)

/** The core's one definition of the synthetic devices. */
internal val kayaSyntheticDevices: List<KayaCaptureDeviceInfo> by lazy {
    val out = ArrayList<KayaCaptureDeviceInfo>()
    var index = 0
    while (true) {
        val line = KayaPresent.captureSynthetic(index) ?: break
        val f = line.split('\n')
        out.add(KayaCaptureDeviceInfo(f[0], f[1], f[2].toInt(), f[3].toInt(), f[4] == "1", f[5].toInt()))
        index += 1
    }
    out
}

/**
 * WHERE A SYNTHETIC DEVICE SITS ON THIS LANE (docs/capture-plan.md §7, OPEN
 * A and B of the breadth notes): the emulator's FRONT camera carries the
 * table's front camera and its BACK camera the other, each showing the flat
 * colour the runner configured it with; its one microphone carries both
 * synthetic microphones, the first on the LEFT channel and the second on
 * the RIGHT, fed by the runner's injected tone.
 */
internal class KayaLaneDevice(val lensFacing: Int?, val channel: Int?)

internal fun kayaLaneDevice(d: KayaCaptureDeviceInfo): KayaLaneDevice =
    if (d.kind == CAPTURE_KIND_CAMERA) {
        KayaLaneDevice(
            if (d.facing == CAMERA_FACING_FRONT) CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK,
            null,
        )
    } else {
        KayaLaneDevice(null, kayaSyntheticDevices.filter { it.kind == CAPTURE_KIND_MICROPHONE }.indexOf(d))
    }

/** Whether this process runs on the emulator, the only place a lane's devices are. */
internal fun kayaOnEmulator(): Boolean = Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish"

/**
 * THE WALL (docs/capture-plan.md §7): under the harness the one device-open
 * route reaches the emulator's own cameras and microphone, which the runner
 * configures with fixed content and refuses a host webcam or host audio for
 * (tools/android/run-emulator.py), and nothing else. Every entry into
 * KayaRealCapture calls this first; tools/check-verbs.py holds it.
 */
internal fun kayaCaptureWall(what: String, device: String, lane: Boolean) {
    if (!kayaCaptureUnderHarness()) return
    if (!lane || !kayaOnEmulator()) {
        error(
            "kaya: $what reaches $device, which is no lane device (hardware ${Build.HARDWARE}), under the " +
                "harness (KAYA_SELFTEST is set); a lane opens the emulator's synthetic devices only " +
                "(docs/capture-plan.md §7)",
        )
    }
}

internal fun kayaReportCaptureState(id: Long, state: Int, reason: Int, format: IntArray, detail: String) {
    KayaPresent.captureState(id, state, reason, format[0], format[1], format[2], detail)
}

internal fun kayaReportDevices(devices: List<KayaCaptureDeviceInfo>) {
    KayaPresent.captureDevicesBegin()
    for (d in devices) KayaPresent.captureDevice(d.id, d.name, d.kind, d.facing, d.preferred)
    KayaPresent.captureDevicesEnd()
}

/** Under the harness: the synthetic table, each entry present when the lane
 * device carrying it is (OPEN A). */
private fun kayaLaneListing(context: Context): List<KayaCaptureDeviceInfo> {
    val (front, back, microphone) = KayaRealCapture.laneDevicesPresent(context)
    return kayaSyntheticDevices.filter { d ->
        val lane = kayaLaneDevice(d)
        when (lane.lensFacing) {
            CameraSelector.LENS_FACING_FRONT -> front
            CameraSelector.LENS_FACING_BACK -> back
            else -> microphone
        }
    }
}

internal fun kayaCaptureRequestPermission(kind: Int) {
    if (kayaCaptureUnderHarness()) {
        val answer = KayaPresent.captureSyntheticPermission(kind, true)
        kayaCaptureMain.post { KayaPresent.capturePermission(kind, answer, "") }
        return
    }
    KayaRealCapture.ask(kind) { answer, detail -> KayaPresent.capturePermission(kind, answer, detail) }
}

internal fun kayaCaptureWatchDevices(on: Boolean) {
    kayaCaptureWatching = on
    if (!on) return
    val context = KayaCompose.kayaAppContext ?: error("kaya: watch_capture_devices before the Compose backend attached")
    if (kayaCaptureUnderHarness()) {
        val standing = listOf(CAPTURE_KIND_CAMERA, CAPTURE_KIND_MICROPHONE)
            .map { it to KayaPresent.captureSyntheticPermission(it, false) }
        val listing = kayaLaneListing(context)
        kayaCaptureMain.post {
            for ((kind, permission) in standing) KayaPresent.capturePermission(kind, permission, "")
            kayaReportDevices(listing)
        }
        return
    }
    for (kind in listOf(CAPTURE_KIND_CAMERA, CAPTURE_KIND_MICROPHONE)) {
        val (now, detail) = KayaRealCapture.permission(context, kind)
        KayaPresent.capturePermission(kind, now, detail)
    }
    KayaRealCapture.devices(context) { kayaReportDevices(it) }
}

/** Each kind's permission in turn, the prompt shown for one still at prompt. */
private fun kayaCaptureAsk(kinds: List<Int>, answers: List<Int>, done: (List<Int>) -> Unit) {
    val kind = kinds.firstOrNull() ?: run {
        kayaCaptureMain.post { done(answers) }
        return
    }
    val rest = kinds.drop(1)
    if (kayaCaptureUnderHarness()) {
        val before = KayaPresent.captureSyntheticPermission(kind, false)
        val answer = KayaPresent.captureSyntheticPermission(kind, true)
        kayaCaptureMain.post {
            if (before != answer) KayaPresent.capturePermission(kind, answer, "")
            kayaCaptureAsk(rest, answers + answer, done)
        }
        return
    }
    KayaRealCapture.ask(kind) { answer, detail ->
        KayaPresent.capturePermission(kind, answer, detail)
        kayaCaptureAsk(rest, answers + answer, done)
    }
}

/** Rule 5 (docs/capture-plan.md §2): a capture with an open camera that a
 * video view previews keeps the screen on. */
internal fun kayaCaptureKeepsAwake(): Boolean =
    KayaSceneModel.videos.any { node -> kayaCaptures[node.videoCapture]?.source?.cameraOpen == true }

/**
 * A capture: the app's devices and wishes, and the source opened from them.
 * The app thread's alone; the source's frames and samples run on threads of
 * their own.
 */
internal class KayaCapture(val id: Long) {
    var camera = ""
    var microphone = ""
    val wish = DoubleArray(3)
    var running = false
    var source: KayaRealCapture.Source? = null
    private var generation = 0

    fun set(prop: Int, value: Any) {
        when (prop) {
            CPROP_CAMERA -> camera = value as String
            CPROP_MICROPHONE -> microphone = value as String
            CPROP_WIDTH -> wish[0] = value as Double
            CPROP_HEIGHT -> wish[1] = value as Double
            CPROP_FRAME_RATE -> wish[2] = value as Double
            // The core keeps the microphone open and delivers the silence.
            CPROP_MUTED -> return
            else -> error("kaya: bad capture prop $prop")
        }
        // A device change while running reopens (docs/capture-plan.md §2).
        if (running) open()
    }

    fun start() {
        if (running) return
        running = true
        open()
        // docs/media-plan.md §7c's bound for a start the platform never answers.
        val at = generation
        kayaCaptureMain.postDelayed({
            if (generation == at && running && KayaPresent.captureOverdue(id) == 1) close()
        }, MEDIA_TIMEOUT_MS.toLong())
    }

    fun stop() {
        running = false
        close()
    }

    private fun close() {
        generation += 1
        source?.stop()
        source = null
        kayaCapturePreviewMoved(id)
    }

    /** The one device-open route: the lane's devices under the harness, the
     * platform's otherwise, each kind's permission asked first. */
    private fun open() {
        close()
        val at = generation
        val kinds = (if (camera.isEmpty()) emptyList() else listOf(CAPTURE_KIND_CAMERA)) +
            (if (microphone.isEmpty()) emptyList() else listOf(CAPTURE_KIND_MICROPHONE))
        kayaCaptureAsk(kinds, emptyList()) { answers ->
            if (generation != at || !running) return@kayaCaptureAsk
            if (answers.contains(PERMISSION_DENIED)) {
                kayaReportCaptureState(id, CAPTURE_STATE_FAILED, CAPTURE_FAILURE_DENIED, IntArray(3),
                    "the user denied this app the camera or the microphone")
                return@kayaCaptureAsk
            }
            val context = KayaCompose.kayaAppContext ?: error("kaya: a capture opened before the Compose backend attached")
            val activity = KayaCompose.activityForLink()
            val opened = if (kayaCaptureUnderHarness()) {
                val cam = kayaSyntheticDevices.firstOrNull { it.id == camera && it.kind == CAPTURE_KIND_CAMERA }
                val mic = kayaSyntheticDevices.firstOrNull { it.id == microphone && it.kind == CAPTURE_KIND_MICROPHONE }
                val listed = kayaLaneListing(context)
                if ((camera.isNotEmpty() && (cam == null || cam !in listed)) ||
                    (microphone.isNotEmpty() && (mic == null || mic !in listed))
                ) {
                    val missing = if (camera.isNotEmpty() && (cam == null || cam !in listed)) camera else microphone
                    kayaReportCaptureState(id, CAPTURE_STATE_FAILED, CAPTURE_FAILURE_NOT_FOUND, IntArray(3),
                        "no device \"$missing\": under the harness only kaya's synthetic devices the lane carries exist")
                    return@kayaCaptureAsk
                }
                KayaRealCapture.open(context, activity, id, cam?.let { kayaLaneDevice(it) }, null,
                    mic?.let { kayaLaneDevice(it) }, null, wish)
            } else {
                KayaRealCapture.open(context, activity, id, null, camera.ifEmpty { null }, null,
                    microphone.ifEmpty { null }, wish)
            }
            opened.fold(
                onSuccess = { source = it },
                onFailure = {
                    Log.w("kaya", "KAYA_CAPTURE_FAILED: capture $id: ${it.message}")
                    val why = it as? KayaCaptureFailure
                    kayaReportCaptureState(id, CAPTURE_STATE_FAILED, why?.reason ?: CAPTURE_FAILURE_HARDWARE_ERROR,
                        IntArray(3), it.message ?: it.toString())
                },
            )
            kayaCapturePreviewMoved(id)
        }
    }
}

internal class KayaCaptureFailure(val reason: Int, detail: String) : Exception(detail)

/** The video views previewing [id] re-read their picture, and the window
 * its keep-awake. */
internal fun kayaCapturePreviewMoved(id: Long) {
    for (node in KayaSceneModel.videos) {
        if (node.videoCapture == id) node.videoSeq += 1
    }
    kayaFollowKeepAwake()
}

internal fun kayaCaptureCreate(id: Long) {
    kayaCaptures[id] = KayaCapture(id)
}

internal fun kayaCaptureRelease(id: Long) {
    kayaCaptures.remove(id)?.stop()
    for (node in KayaSceneModel.videos) {
        if (node.videoCapture == id) {
            node.videoCapture = 0L
            node.videoSeq += 1
        }
    }
    kayaFollowKeepAwake()
}

internal fun kayaCaptureCommand(id: Long, command: Int) {
    val c = kayaCaptures[id] ?: return
    if (command == CAPTURE_COMMAND_START) c.start() else c.stop()
    kayaFollowKeepAwake()
}

/** The preview (docs/capture-plan.md §3): CameraX's PreviewView in
 * PERFORMANCE mode, a SurfaceView, the media plan's hole, which mirrors a
 * front camera's self-view by itself (rule 4); nothing at all while the
 * capture has no open camera, so the view shows its ground. */
@Composable
internal fun KayaCapturePreview(node: KayaNode, fill: Boolean) {
    node.videoSeq
    val source = kayaCaptures[node.videoCapture]?.source
    if (source?.cameraOpen != true) return
    AndroidView(
        factory = { context ->
            PreviewView(context).apply {
                implementationMode = PreviewView.ImplementationMode.PERFORMANCE
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            }
        },
        update = { view ->
            view.scaleType = if (fill) PreviewView.ScaleType.FILL_CENTER else PreviewView.ScaleType.FIT_CENTER
            source.attach(view)
        },
        modifier = Modifier.fillMaxSize().clearAndSetSemantics {},
    )
    DisposableEffect(source) {
        onDispose { source.detach() }
    }
}

/** expect_video_ink's diagnostic line for a capture preview; null when frames arrive. */
internal fun kayaCaptureFramesWhyNot(node: KayaNode): String? {
    val c = kayaCaptures[node.videoCapture] ?: return "the view previews no capture (capture ${node.videoCapture})"
    val s = c.source ?: return "capture ${c.id} has no open source (running ${c.running})"
    if (!s.cameraOpen) return "capture ${c.id} has no camera open"
    if (!s.previewAttached) return "capture ${c.id}'s preview has no view attached"
    return if (s.frames == 0L) "capture ${c.id} has handed the core no frame yet" else null
}

/**
 * EVERY REAL CAMERA AND MICROPHONE IS REACHED HERE AND NOWHERE ELSE
 * (docs/capture-plan.md §7): CameraX, Camera2's characteristics, AudioRecord
 * and the runtime permission prompt are named only inside this object, and
 * each entry calls kayaCaptureWall first. tools/check-verbs.py reads it.
 */
internal object KayaRealCapture {
    fun permission(context: Context, kind: Int): Pair<Int, String> {
        kayaCaptureWall("reading a capture permission", "the $kind permission", false)
        val name = if (kind == CAPTURE_KIND_CAMERA) Manifest.permission.CAMERA else Manifest.permission.RECORD_AUDIO
        return when {
            ContextCompat.checkSelfPermission(context, name) == PackageManager.PERMISSION_GRANTED -> PERMISSION_GRANTED to ""
            kind in refused -> PERMISSION_DENIED to "the user refused it; Settings can grant it"
            else -> PERMISSION_PROMPT to ""
        }
    }

    private val refused = HashSet<Int>()

    /** The platform's prompt for a kind still at prompt, answered on the app thread. */
    fun ask(kind: Int, done: (Int, String) -> Unit) {
        kayaCaptureWall("asking for a capture permission", "the $kind permission", false)
        val context = KayaCompose.kayaAppContext ?: error("kaya: a permission asked before the Compose backend attached")
        val now = permission(context, kind)
        val activity = KayaCompose.activityForLink()
        if (now.first != PERMISSION_PROMPT || activity == null) {
            kayaCaptureMain.post { done(now.first, if (activity == null) "no activity to ask from" else now.second) }
            return
        }
        val name = if (kind == CAPTURE_KIND_CAMERA) Manifest.permission.CAMERA else Manifest.permission.RECORD_AUDIO
        var launcher: androidx.activity.result.ActivityResultLauncher<String>? = null
        launcher = activity.activityResultRegistry.register(
            "dev.kaya.capture.permission.$kind", ActivityResultContracts.RequestPermission(),
        ) { granted ->
            launcher?.unregister()
            if (!granted) refused.add(kind)
            done(if (granted) PERMISSION_GRANTED else PERMISSION_DENIED, "")
        }
        launcher.launch(name)
    }

    /** Under the harness: which lane devices exist (front camera, back camera, a microphone). */
    fun laneDevicesPresent(context: Context): Triple<Boolean, Boolean, Boolean> {
        kayaCaptureWall("listing the lane's cameras and microphone", "the emulator's devices", true)
        val manager = context.getSystemService(android.hardware.camera2.CameraManager::class.java)
        val facings = manager.cameraIdList.map { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) }
        val audio = context.getSystemService(AudioManager::class.java)
        val microphone = audio.getDevices(AudioManager.GET_DEVICES_INPUTS).any { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
        return Triple(
            facings.contains(CameraCharacteristics.LENS_FACING_FRONT),
            facings.contains(CameraCharacteristics.LENS_FACING_BACK),
            microphone,
        )
    }

    /** The platform's cameras and microphones, the preferred camera the first
     * front one (the call's self-view) and the preferred microphone the
     * built-in one. */
    @SuppressLint("UnsafeOptInUsageError")
    fun devices(context: Context, done: (List<KayaCaptureDeviceInfo>) -> Unit) {
        kayaCaptureWall("listing the cameras and microphones", "the platform's devices", false)
        val manager = context.getSystemService(android.hardware.camera2.CameraManager::class.java)
        val cameras = manager.cameraIdList.map { id ->
            val facing = when (manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> CAMERA_FACING_FRONT
                CameraCharacteristics.LENS_FACING_BACK -> CAMERA_FACING_BACK
                CameraCharacteristics.LENS_FACING_EXTERNAL -> CAMERA_FACING_EXTERNAL
                else -> CAMERA_FACING_UNKNOWN
            }
            Triple(id, facing, "Camera $id")
        }
        val preferredCamera = cameras.firstOrNull { it.second == CAMERA_FACING_FRONT }?.first ?: cameras.firstOrNull()?.first
        val audio = context.getSystemService(AudioManager::class.java)
        val inputs = audio.getDevices(AudioManager.GET_DEVICES_INPUTS).toList()
        val preferredMicrophone = inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }?.id ?: inputs.firstOrNull()?.id
        val out = cameras.map { (id, facing, name) ->
            KayaCaptureDeviceInfo(id, name, CAPTURE_KIND_CAMERA, facing, id == preferredCamera, 0)
        } + inputs.map { d ->
            KayaCaptureDeviceInfo("microphone:${d.id}", d.productName.toString(), CAPTURE_KIND_MICROPHONE,
                CAMERA_FACING_UNKNOWN, d.id == preferredMicrophone, 0)
        }
        kayaCaptureMain.post { done(out) }
    }

    /** The one device-open function. Under the harness [laneCamera] and
     * [laneMicrophone] name the emulator's devices and [cameraId] and
     * [microphoneId] are null; off it the reverse. */
    fun open(
        context: Context,
        activity: ComponentActivity?,
        capture: Long,
        laneCamera: KayaLaneDevice?,
        cameraId: String?,
        laneMicrophone: KayaLaneDevice?,
        microphoneId: String?,
        wish: DoubleArray,
    ): Result<Source> {
        kayaCaptureWall("opening a camera or a microphone", listOfNotNull(cameraId, microphoneId).joinToString(" and ")
            .ifEmpty { "the emulator's camera and microphone" }, cameraId == null && microphoneId == null)
        val hasCamera = laneCamera != null || cameraId != null
        val hasMicrophone = laneMicrophone != null || microphoneId != null
        if (hasCamera && activity == null) {
            return Result.failure(KayaCaptureFailure(CAPTURE_FAILURE_HARDWARE_ERROR, "no activity to bind the camera to"))
        }
        val source = Source(context, capture, hasCamera, hasMicrophone)
        if (hasMicrophone) {
            val failed = source.openMicrophone(context, laneMicrophone?.channel, microphoneId)
            if (failed != null) {
                source.stop()
                return Result.failure(failed)
            }
        }
        if (hasCamera) {
            source.openCamera(context, activity!!, laneCamera?.lensFacing, cameraId, wish)
        } else {
            source.ready()
        }
        return Result.success(source)
    }

    @OptIn(ExperimentalCamera2Interop::class)
    class Source(private val context: Context, val capture: Long, hasCamera: Boolean, private val hasMicrophone: Boolean) {
        /** The chosen format, (0, 0, 0) with no camera. */
        val format = IntArray(3)
        @Volatile var cameraOpen = hasCamera
        @Volatile var frames = 0L
        var previewAttached = false
        private var stopped = false
        private var reported = false
        private var provider: ProcessCameraProvider? = null
        private var owner: ComponentActivity? = null
        private var selector: CameraSelector? = null
        private var analysis: ImageAnalysis? = null
        private var preview: Preview? = null
        private var resolution: ResolutionSelector? = null
        private var aspect: AspectRatioStrategy? = null
        private var fps: Range<Int>? = null
        private var bound: Camera? = null
        private var boundCases: List<UseCase> = emptyList()
        private var view: PreviewView? = null
        private val frameThread: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "kaya-capture-$capture") }
        private var record: AudioRecord? = null
        private var audioThread: Thread? = null
        @Volatile private var audioRunning = false
        private var layoutSaid = false

        /** Running, once each part this capture asked for has started. */
        fun ready() {
            kayaCaptureMain.post {
                if (stopped || reported) return@post
                if (cameraOpen && frames == 0L) return@post
                reported = true
                KayaPresent.captureState(capture, CAPTURE_STATE_RUNNING, 0, format[0], format[1], format[2], "")
            }
        }

        private fun fail(reason: Int, detail: String) {
            Log.w("kaya", "KAYA_CAPTURE_FAILED: capture $capture reason $reason: $detail")
            kayaCaptureMain.post {
                if (stopped) return@post
                KayaPresent.captureState(capture, CAPTURE_STATE_FAILED, reason, 0, 0, 0, detail)
            }
        }

        fun openCamera(context: Context, activity: ComponentActivity, lensFacing: Int?, cameraId: String?, wish: DoubleArray) {
            kayaCaptureWall("opening a camera", cameraId ?: "the emulator's camera", cameraId == null)
            owner = activity
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener({
                if (stopped) return@addListener
                val p = try {
                    future.get()
                } catch (e: Exception) {
                    fail(CAPTURE_FAILURE_HARDWARE_ERROR, "CameraX did not start: $e")
                    return@addListener
                }
                provider = p
                val info: CameraInfo? = p.availableCameraInfos.firstOrNull { i ->
                    if (cameraId != null) {
                        Camera2CameraInfo.from(i).cameraId == cameraId
                    } else {
                        i.lensFacing == lensFacing
                    }
                }
                if (info == null) {
                    fail(CAPTURE_FAILURE_NOT_FOUND, "no camera ${cameraId ?: "facing $lensFacing"} among CameraX's " +
                        "${p.availableCameraInfos.size}")
                    return@addListener
                }
                val chars = Camera2CameraInfo.from(info)
                val map = chars.getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                val ranges = chars.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                    ?: emptyArray()
                val rates = ranges.map { it.upper }.toSortedSet()
                val offered = ArrayList<Int>()
                for (size in map?.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray()) {
                    val fastest = map!!.getOutputMinFrameDuration(ImageFormat.YUV_420_888, size)
                    for (rate in rates) {
                        if (fastest == 0L || fastest <= 1_000_000_000L / rate + 1000) offered += listOf(size.width, size.height, rate)
                    }
                }
                val chosen = KayaPresent.captureNearestFormat(offered.toIntArray(), wish[0], wish[1], wish[2])
                if (chosen == null) {
                    fail(CAPTURE_FAILURE_UNSUPPORTED, "the camera offers no YUV format")
                    return@addListener
                }
                chosen.copyInto(format)
                val size = Size(chosen[0], chosen[1])
                fps = ranges.filter { it.upper == chosen[2] }.minByOrNull { it.upper - it.lower }
                val ratio = if (size.width * 3 == size.height * 4) AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY
                else AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY
                aspect = ratio
                resolution = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(ratio)
                    .setResolutionStrategy(ResolutionStrategy(size, ResolutionStrategy.FALLBACK_RULE_NONE))
                    .setResolutionFilter { sizes, _ -> sizes.filter { it == size } }
                    .build()
                selector = CameraSelector.Builder().addCameraFilter { infos -> infos.filter { it == info } }.build()
                val analysisBuilder = ImageAnalysis.Builder()
                    .setResolutionSelector(resolution!!)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                fps?.let { Camera2Interop.Extender(analysisBuilder).setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                analysis = analysisBuilder.build().also { a -> a.setAnalyzer(frameThread) { image -> frame(image) } }
                bind()
            }, ContextCompat.getMainExecutor(context))
        }

        /** The camera's use cases on the activity's lifecycle: the frames
         * always, the preview while a view shows it. */
        private fun bind() {
            val p = provider ?: return
            val o = owner ?: return
            val s = selector ?: return
            if (stopped) return
            val cases = ArrayList<UseCase>()
            analysis?.let { cases += it }
            val v = view
            if (v != null) {
                // The preview keeps the platform's own size at the frames'
                // aspect: a preview stream past the display's own size is out
                // of the guaranteed combinations, and 1280x720 beside the
                // analysis's was refused on the pool's 360x800 phone.
                val builder = Preview.Builder().setResolutionSelector(
                    ResolutionSelector.Builder().setAspectRatioStrategy(aspect!!).build(),
                )
                fps?.let { Camera2Interop.Extender(builder).setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                preview = builder.build().also { it.setSurfaceProvider(v.surfaceProvider) }
                cases += preview!!
            } else {
                preview = null
            }
            bound?.cameraInfo?.cameraState?.removeObservers(o)
            try {
                p.unbind(*boundCases.toTypedArray())
                boundCases = cases
                bound = p.bindToLifecycle(o, s, *cases.toTypedArray())
            } catch (e: SecurityException) {
                fail(CAPTURE_FAILURE_DENIED, "the platform refused the camera: ${e.message}")
                return
            } catch (e: Exception) {
                fail(CAPTURE_FAILURE_UNSUPPORTED, "CameraX could not bind the camera at ${format[0]}x${format[1]}@${format[2]}: $e")
                return
            }
            previewAttached = v != null
            bound?.cameraInfo?.cameraState?.observe(o) { state ->
                val error = state.error ?: return@observe
                val reason = when (error.code) {
                    CameraState.ERROR_CAMERA_IN_USE, CameraState.ERROR_MAX_CAMERAS_IN_USE -> CAPTURE_FAILURE_IN_USE
                    CameraState.ERROR_CAMERA_DISABLED, CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED -> CAPTURE_FAILURE_DENIED
                    CameraState.ERROR_STREAM_CONFIG -> CAPTURE_FAILURE_UNSUPPORTED
                    CameraState.ERROR_CAMERA_REMOVED -> CAPTURE_FAILURE_DISCONNECTED
                    else -> CAPTURE_FAILURE_HARDWARE_ERROR
                }
                if (state.type == CameraState.Type.CLOSED || reason != CAPTURE_FAILURE_HARDWARE_ERROR) {
                    fail(reason, "CameraX reported camera error ${error.code}: ${error.cause ?: "no cause"}")
                }
            }
        }

        fun attach(v: PreviewView) {
            if (view === v && previewAttached) return
            view = v
            bind()
        }

        fun detach() {
            if (view == null) return
            view = null
            bind()
        }

        /** A frame, on the capture's own thread: YUV_420_888 as NV12 to the core. */
        private fun frame(image: ImageProxy) {
            image.use {
                if (stopped) return
                val planes = it.planes
                val how = KayaPresent.captureFrame(
                    capture, it.width, it.height,
                    planes[0].buffer, planes[0].rowStride, planes[0].pixelStride,
                    planes[1].buffer, planes[1].rowStride, planes[1].pixelStride,
                    planes[2].buffer, planes[2].rowStride, planes[2].pixelStride,
                    it.imageInfo.timestamp, it.imageInfo.rotationDegrees,
                )
                if (!layoutSaid) {
                    layoutSaid = true
                    Log.i("kaya", "KAYA_CAPTURE_LAYOUT: ${it.width}x${it.height} y ${planes[0].rowStride}/" +
                        "${planes[0].pixelStride} u ${planes[1].rowStride}/${planes[1].pixelStride} v " +
                        "${planes[2].rowStride}/${planes[2].pixelStride} -> ${if (how == 1) "NV12 in place" else "repacked"}")
                }
                frames += 1
                if (frames == 1L) ready()
            }
        }

        /** The microphone on its own thread: float samples to the core at the
         * device's own rate and channels; under the harness the lane's one
         * input carries two synthetic microphones, so the bound channel alone
         * goes in, as mono (OPEN B). */
        @SuppressLint("MissingPermission")
        fun openMicrophone(context: Context, laneChannel: Int?, microphoneId: String?): KayaCaptureFailure? {
            kayaCaptureWall("opening a microphone", microphoneId ?: "the emulator's microphone", microphoneId == null)
            val rate = 48_000
            val channels = 2
            val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
            val r = try {
                AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate, AudioFormat.CHANNEL_IN_STEREO,
                    AudioFormat.ENCODING_PCM_FLOAT, maxOf(min, rate / 10 * channels * 4))
            } catch (e: SecurityException) {
                return KayaCaptureFailure(CAPTURE_FAILURE_DENIED, "the platform refused the microphone: ${e.message}")
            } catch (e: IllegalArgumentException) {
                return KayaCaptureFailure(CAPTURE_FAILURE_UNSUPPORTED, "AudioRecord refused 48 kHz stereo float: ${e.message}")
            }
            if (r.state != AudioRecord.STATE_INITIALIZED) {
                r.release()
                return KayaCaptureFailure(CAPTURE_FAILURE_HARDWARE_ERROR, "AudioRecord did not initialize (state ${r.state})")
            }
            if (microphoneId != null) {
                val want = microphoneId.removePrefix("microphone:").toIntOrNull()
                val device = context.getSystemService(AudioManager::class.java)
                    .getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == want }
                if (device == null) {
                    r.release()
                    return KayaCaptureFailure(CAPTURE_FAILURE_NOT_FOUND, "no microphone \"$microphoneId\"")
                }
                r.preferredDevice = device
            }
            record = r
            audioRunning = true
            val actualRate = r.sampleRate
            val actualChannels = r.channelCount
            val refused = startRecord(r)
            if (refused != null) {
                record = null
                audioRunning = false
                r.release()
                return refused
            }
            audioThread = Thread({
                val buf = FloatArray(actualRate / 100 * actualChannels)
                val mono = FloatArray(actualRate / 100)
                var said = false
                while (audioRunning) {
                    val n = r.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
                    if (n <= 0) {
                        if (n < 0 && audioRunning) fail(CAPTURE_FAILURE_HARDWARE_ERROR, "AudioRecord.read answered $n")
                        break
                    }
                    if (!said) {
                        said = true
                        Log.i("kaya", "KAYA_CAPTURE_AUDIO: $actualRate Hz, $actualChannels channel(s), float")
                        // The lane's tone may start only once the guest's input
                        // DELIVERS: an injection with no capture open ends the
                        // emulator, a record made and not started included, and
                        // under load a started record whose first read had not
                        // come back yet included
                        // (docs/probes/capture-2026-10-01/compose-measured.md).
                        if (laneChannel != null) kayaLaneToneRequest()
                    }
                    val at = System.nanoTime()
                    if (laneChannel != null && actualChannels > 1) {
                        val frames = n / actualChannels
                        for (i in 0 until frames) mono[i] = buf[i * actualChannels + laneChannel.coerceAtMost(actualChannels - 1)]
                        KayaPresent.captureSamples(capture, 1, actualRate, mono, frames, at)
                    } else {
                        KayaPresent.captureSamples(capture, actualChannels, actualRate, buf, n, at)
                    }
                }
            }, "kaya-capture-audio-$capture")
            audioThread!!.start()
            return null
        }

        private fun startRecord(r: AudioRecord): KayaCaptureFailure? {
            try {
                r.startRecording()
            } catch (e: IllegalStateException) {
                return KayaCaptureFailure(CAPTURE_FAILURE_IN_USE, "AudioRecord would not start: ${e.message}")
            }
            if (r.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                return KayaCaptureFailure(CAPTURE_FAILURE_IN_USE, "AudioRecord is not recording (another app holds the input)")
            }
            return null
        }

        /** Stop closes the devices and puts the preview out. */
        fun stop() {
            if (stopped) return
            stopped = true
            cameraOpen = false
            owner?.let { o -> bound?.cameraInfo?.cameraState?.removeObservers(o) }
            try {
                provider?.unbind(*boundCases.toTypedArray())
            } catch (e: IllegalStateException) {
                Log.w("kaya", "kaya: CameraX unbind on stop: $e")
            }
            analysis?.clearAnalyzer()
            frameThread.shutdown()
            val r = record
            if (r != null) {
                audioRunning = false
                val thread = audioThread
                Thread({
                    r.stop()
                    thread?.join(2000)
                    r.release()
                }, "kaya-capture-close-$capture").start()
            }
            record = null
        }
    }
}

/** The runner's tone on the emulator's microphone (tools/lib/emulator_capture.py),
 * asked for by number. */
private val kayaLaneToneRequests = java.util.concurrent.atomic.AtomicInteger()

private fun kayaLaneToneRequest(): Int {
    val seq = kayaLaneToneRequests.incrementAndGet()
    Log.i("kaya", "KAYA_REQUEST: microphone $seq")
    return seq
}

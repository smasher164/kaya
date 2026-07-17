// record-suite: one suite-long recording of every registered guest
// window, via a single ScreenCaptureKit stream. The recording-mode
// capturer for macOS.
//
//   record-suite <output.mov> <pidfile>
//   record-suite --probe
//
// One stream on purpose: concurrent SCK window streams starve and die
// ("connection interrupted", frameless legs) where a single stream is
// reliable — so parallel legs share this stream and become crops. The
// filter is display-scoped but INCLUDE-LISTED: only windows owned by
// pids in <pidfile> (runner-appended, polled live) are composited;
// everything else on the display never appears in the film. Guests
// tile themselves into slots (KAYA_WIN_SLOT) so crops never overlap.
//
// Protocol on stdout, consumed by tools/validate-mac.sh:
//   RECORDING_START <epoch_ms>    wall time of video t=0 (the anchor)
//   SCALE <n>                     display points -> video pixels
//   TRACKING <pid>                the pid's window has joined the filter
//   WINDOW <pid> <x> <y> <w> <h>  its frame, display points, top-left
//
// Frames are written with AVAssetWriter (SCRecordingOutput flushes in
// ~2s chunks and drops the buffered tail at stop). Frame 0 is seeded
// from an explicit screenshot: SCK streams only deliver on content
// change, and a leg gated on "recording started" holds still — the
// seed breaks that deadlock, guarantees the initial state is in the
// film, and stamps the anchor. On SIGINT/SIGTERM the recorder drains
// until frames go idle, then finalizes — no fixed grace anywhere.
//
// Never rebuild this binary in place: repeated rebuilds at one path
// poison that identity's standing with the capture stack (hangs, bogus
// TCC declines) and the damage survives reboots. The runner builds it
// to a content-hashed path.

import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("record-suite: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// --probe: report whether screen capture is answering, in seconds — a
// wedged capture stack aborts a recorded suite up front with
// instructions instead of failing every leg.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--probe" {
    Task {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            print("PROBE OK")
            exit(0)
        } catch {
            print("PROBE DENIED: \(error.localizedDescription)")
            exit(1)
        }
    }
    Task {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        print("PROBE DENIED: shareable-content query hung for 10s")
        exit(1)
    }
    dispatchMain()
}

final class Writer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var lastPTS = CMTime.invalid
    // Written on the sample queue, read by the quiesce poll (which
    // hops onto the same queue) — see quiesced(on:).
    private var lastAppend = Date.distantPast

    init(output: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
    }

    // Frame 0, written on the caller's initiative; video t=0 == this
    // wall-clock moment, which is what RECORDING_START reports.
    func seed(_ image: CGImage, queue: DispatchQueue) {
        queue.sync {
            guard !started else { return }
            guard writer.startWriting() else {
                fail("writer: \(writer.error?.localizedDescription ?? "startWriting failed")")
            }
            guard let pool = adaptor.pixelBufferPool else {
                fail("writer: no pixel buffer pool")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { fail("writer: pixel buffer alloc failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(image, in: CGRect(
                x: 0, y: 0,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer)))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            writer.startSession(atSourceTime: pts)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                fail("writer: \(writer.error?.localizedDescription ?? "seed append failed")")
            }
            started = true
            lastPTS = pts
            lastAppend = Date()
            print("RECORDING_START \(Int(Date().timeIntervalSince1970 * 1000))")
            fflush(stdout)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, started else { return }
        // SCK also delivers status-only buffers (idle, blank); only
        // complete frames carry image data worth writing.
        guard let infos = CMSampleBufferGetSampleAttachmentsArray(
                buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = infos.first?[.status] as? Int,
            statusRaw == SCFrameStatus.complete.rawValue
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        // Frames captured before the seed would step the session's
        // clock backwards; drop them.
        guard CMTimeCompare(pts, lastPTS) > 0 else { return }
        if input.isReadyForMoreMediaData, input.append(buffer) {
            lastPTS = pts
            lastAppend = Date()
        }
    }

    // A stream that dies on its own must say so — a frameless video
    // with a silent recorder cost a debugging round.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            "record-suite: stream stopped: \(error.localizedDescription)\n".data(using: .utf8)!)
    }

    // True once no frame has arrived for `idle` seconds; the stop path
    // waits for the pipe to drain instead of assuming a fixed latency.
    func quiesced(on queue: DispatchQueue, idle: TimeInterval) -> Bool {
        queue.sync { started && Date().timeIntervalSince(lastAppend) > idle }
    }

    func finish(_ done: @escaping () -> Void) {
        guard started else { exit(0) }
        input.markAsFinished()
        // Extend the timeline to the stop moment, so duration reflects
        // when capture stopped rather than when content last changed.
        writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
        writer.finishWriting(completionHandler: done)
    }
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: record-suite <output.mov> <pidfile>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let pidfile = CommandLine.arguments[2]
try? FileManager.default.removeItem(at: output)

// ScreenCaptureKit needs a window-server connection and a real AppKit
// run loop on the main thread — a faceless NSApplication provides both.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// Retained at file scope so the handlers outlive the setup Task.
var signalSources: [DispatchSourceSignal] = []

Task {
  // Nothing in this path may fail silently: a thrown error must land
  // in the log, not die with the Task while the process idles.
  do {
    let content0 = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
    guard let display = content0.displays.first else { fail("no display") }

    var tracked: [pid_t: SCWindow] = [:]
    var stream: SCStream?
    let sampleQueue = DispatchQueue(label: "record")

    while true {
        let pids = (try? String(contentsOfFile: pidfile, encoding: .utf8))
            .map { $0.split(separator: "\n").compactMap { pid_t($0) } } ?? []
        if !pids.isEmpty {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            var changed = false
            var joined: [pid_t] = []
            for pid in pids where tracked[pid] == nil {
                // A pid owns more than one "window" (menu bar, status
                // items); the scene window has real dimensions.
                if let win = content.windows.first(where: {
                    $0.owningApplication?.processID == pid
                        && $0.frame.width > 50 && $0.frame.height > 50
                }) {
                    tracked[pid] = win
                    joined.append(pid)
                    changed = true
                }
            }
            // Windows of exited guests leave the filter so it never
            // holds stale ids.
            for (pid, _) in tracked where kill(pid, 0) != 0 {
                tracked[pid] = nil
                changed = true
            }
            if changed {
                let filter = SCContentFilter(display: display, including: Array(tracked.values))
                if let stream {
                    try await stream.updateContentFilter(filter)
                } else if !tracked.isEmpty {
                    let config = SCStreamConfiguration()
                    let scale = CGFloat(filter.pointPixelScale)
                    config.width = Int(display.frame.width * scale)
                    config.height = Int(display.frame.height * scale)
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    config.showsCursor = false
                    let writer = try Writer(
                        output: output, width: config.width, height: config.height)
                    let s = SCStream(filter: filter, configuration: config, delegate: writer)
                    try s.addStreamOutput(writer, type: .screen, sampleHandlerQueue: sampleQueue)
                    try await s.startCapture()
                    // Seed frame 0 explicitly — see Writer.seed.
                    let shot = try await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: config)
                    writer.seed(shot, queue: sampleQueue)
                    print("SCALE \(filter.pointPixelScale)")
                    stream = s

                    // Dispatch sources rather than signal(): the stop
                    // path captures the stream, which a C signal
                    // handler cannot. The watchdog is a separate Task
                    // on purpose: stopCapture itself can hang, and a
                    // fallback sequenced after it would never run.
                    for sig in [SIGINT, SIGTERM] {
                        signal(sig, SIG_IGN)
                        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                        source.setEventHandler {
                            Task {
                                try? await Task.sleep(nanoseconds: 15_000_000_000)
                                FileHandle.standardError.write(
                                    "record-suite: stop path wedged; hard exit\n"
                                        .data(using: .utf8)!)
                                exit(2)
                            }
                            Task {
                                for _ in 0..<40 {
                                    if writer.quiesced(on: sampleQueue, idle: 1.5) { break }
                                    try? await Task.sleep(nanoseconds: 200_000_000)
                                }
                                try? await s.stopCapture()
                                writer.finish { exit(0) }
                                // Bound on a completion handler that
                                // never comes.
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                exit(0)
                            }
                        }
                        source.resume()
                        signalSources.append(source)
                    }
                }
                for pid in joined {
                    let f = tracked[pid]!.frame
                    print("TRACKING \(pid)")
                    print("WINDOW \(pid) \(Int(f.origin.x)) \(Int(f.origin.y)) \(Int(f.width)) \(Int(f.height))")
                }
                fflush(stdout)
            }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
    }
  } catch {
    fail("setup: \(error.localizedDescription)")
  }
}

app.run()

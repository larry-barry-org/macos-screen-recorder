import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ScreenCaptureKit

enum RecState {
    case idle
    case recording
    case paused
}

/// Captures a screen region + system audio via ScreenCaptureKit and writes it
/// to an .mov file with AVAssetWriter. Supports pause/resume by removing the
/// paused interval from the sample timeline.
final class RecordingManager: NSObject, SCStreamOutput, SCStreamDelegate {

    var onStateChange: ((RecState, URL?) -> Void)?
    var onError: ((String) -> Void)?
    /// Emits a small downscaled preview of the latest recorded frame (~10 fps,
    /// on the main queue) for the live menu-bar thumbnail.
    var onFrame: ((CGImage) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.local.ScreenRecorder.samples")
    private let ciContext = CIContext()
    private var frameCounter = 0

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?

    private var state: RecState = .idle

    // Timeline bookkeeping (all mutated on sampleQueue).
    private var sessionStarted = false
    private var baseline: CMTime = .invalid
    private var pausedAccum: CMTime = .zero
    private var pauseStartPTS: CMTime = .zero
    private var lastPTS: CMTime = .zero
    private var justResumed = false

    enum RecError: LocalizedError {
        case permissionDenied
        case noDisplay
        case setupFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission is required.\n\nGrant it in System Settings → Privacy & Security → Screen Recording, then relaunch the app and try again."
            case .noDisplay:
                return "Couldn't find a display for the selected region. Try selecting the region again."
            case .setupFailed(let msg):
                return "Failed to start recording: \(msg)"
            }
        }
    }

    // MARK: - Public control

    func start(region: CGRect) {
        Task {
            do {
                try await performStart(region: region)
            } catch {
                await MainActor.run {
                    self.onError?((error as? RecError)?.errorDescription ?? error.localizedDescription)
                    self.notify(.idle, url: nil)
                }
            }
        }
    }

    func stop() {
        Task { await performStop() }
    }

    func pause() {
        sampleQueue.async {
            guard self.state == .recording else { return }
            self.pauseStartPTS = self.lastPTS
            self.state = .paused
            self.notify(.paused, url: nil)
        }
    }

    func resume() {
        sampleQueue.async {
            guard self.state == .paused else { return }
            self.justResumed = true
            self.state = .recording
            self.notify(.recording, url: nil)
        }
    }

    // MARK: - Start

    private func performStart(region: CGRect) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw RecError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Pick the display with the largest overlap with the region.
        guard let screen = NSScreen.screens.max(by: {
            area($0.frame.intersection(region)) < area($1.frame.intersection(region))
        }) ?? NSScreen.main,
              let displayID = screenNumber(screen),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw RecError.noDisplay }

        // Convert the global region to display-local, top-left-origin points.
        let scale = screen.backingScaleFactor
        var localX = region.minX - screen.frame.minX
        var localY = screen.frame.maxY - region.maxY // flip Y
        var width = region.width
        var height = region.height

        // Clamp to the display bounds.
        localX = max(0, min(localX, screen.frame.width - 1))
        localY = max(0, min(localY, screen.frame.height - 1))
        width = min(width, screen.frame.width - localX)
        height = min(height, screen.frame.height - localY)

        let sourceRect = CGRect(x: localX, y: localY, width: width, height: height)
        let pixelWidth = even(Int((width * scale).rounded()))
        let pixelHeight = even(Int((height * scale).rounded()))
        guard pixelWidth >= 2, pixelHeight >= 2 else {
            throw RecError.setupFailed("region too small")
        }

        // Stream configuration.
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 fps
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.sampleRate = 48_000
        config.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Output file.
        let url = makeOutputURL()
        try setupWriter(url: url, width: pixelWidth, height: pixelHeight)
        outputURL = url

        // Reset timeline state.
        sampleQueue.sync {
            sessionStarted = false
            baseline = .invalid
            pausedAccum = .zero
            pauseStartPTS = .zero
            lastPTS = .zero
            justResumed = false
            frameCounter = 0
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        sampleQueue.sync { self.state = .recording }
        notify(.recording, url: nil)
    }

    private func setupWriter(url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecError.setupFailed("writer inputs rejected")
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw RecError.setupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    // MARK: - Stop

    private func performStop() async {
        let wasActive: Bool = sampleQueue.sync {
            guard state != .idle else { return false }
            state = .idle
            return true
        }
        guard wasActive else { return }

        try? await stream?.stopCapture()

        sampleQueue.sync {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
        }
        await writer?.finishWriting()

        let url = outputURL
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil

        notify(.idle, url: url)
    }

    // MARK: - Sample handling (runs on sampleQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if type == .screen && !isFrameComplete(sampleBuffer) { return }
        guard state == .recording else { return } // drop while paused/idle

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Start the writer session on the first complete video frame.
        if !sessionStarted {
            guard type == .screen else { return }
            baseline = pts
            writer?.startSession(atSourceTime: .zero)
            sessionStarted = true
        }

        // Account for time spent paused.
        if justResumed {
            pausedAccum = CMTimeAdd(pausedAccum, CMTimeSubtract(pts, pauseStartPTS))
            justResumed = false
        }
        lastPTS = pts

        let offset = CMTimeAdd(baseline, pausedAccum)
        guard let retimed = retime(sampleBuffer, by: offset) else { return }

        switch type {
        case .screen:
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(retimed)
            }
            emitThumbnailIfNeeded(sampleBuffer)
        case .audio:
            if audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(retimed)
            }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { await performStop() }
    }

    // MARK: - Helpers

    /// Downscale roughly every 6th frame (~10 fps) into a small CGImage for the
    /// menu-bar preview. Runs on sampleQueue; delivers on the main queue.
    private func emitThumbnailIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        frameCounter += 1
        guard frameCounter % 6 == 0,
              let onFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvImageBuffer: pixelBuffer)
        guard ci.extent.height > 0 else { return }
        let targetHeight: CGFloat = 240
        let scale = targetHeight / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        DispatchQueue.main.async { onFrame(cg) }
    }

    private func isFrameComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attach = arr.first,
              let raw = attach[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    private func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }

        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)

        for i in 0..<infos.count {
            if infos[i].presentationTimeStamp.isValid {
                infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            }
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
            }
        }

        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &out
        )
        return out
    }

    private func makeOutputURL() -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "ScreenRecording_\(fmt.string(from: Date())).mov"
        return dir.appendingPathComponent(name)
    }

    private func notify(_ state: RecState, url: URL?) {
        DispatchQueue.main.async { self.onStateChange?(state, url) }
    }

    private func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    private func even(_ x: Int) -> Int { x % 2 == 0 ? x : x + 1 }
}

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
        case windowUnavailable
        case setupFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission is required.\n\nGrant it in System Settings → Privacy & Security → Screen Recording, then relaunch the app and try again."
            case .noDisplay:
                return "Couldn't find a display for the selected region. Try selecting the region again."
            case .windowUnavailable:
                return "The bound window isn't available (it may be closed or minimized). Choose “Select Window…” again."
            case .setupFailed(let msg):
                return "Failed to start recording: \(msg)"
            }
        }
    }

    // MARK: - Public control

    func start(target: CaptureTarget) {
        Task {
            do {
                try await performStart(target: target)
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

    private func performStart(target: CaptureTarget) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw RecError.permissionDenied
        }

        let (filter, config) = try await buildFilterAndConfig(for: target)

        let url = makeOutputURL()
        try setupWriter(url: url, width: config.width, height: config.height)
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

    /// Builds the ScreenCaptureKit filter + configuration for either a display
    /// region or a specific window (with an optional sub-region crop).
    private func buildFilterAndConfig(for target: CaptureTarget) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        switch target {
        case .displayRegion(let region):
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
            localX = max(0, min(localX, screen.frame.width - 1))
            localY = max(0, min(localY, screen.frame.height - 1))
            width = min(width, screen.frame.width - localX)
            height = min(height, screen.frame.height - localY)

            let sourceRect = CGRect(x: localX, y: localY, width: width, height: height)
            let config = makeConfig(sourceRect: sourceRect,
                                    pixelWidth: even(Int((width * scale).rounded())),
                                    pixelHeight: even(Int((height * scale).rounded())))
            return (SCContentFilter(display: display, excludingWindows: []), config)

        case .window(let spec):
            guard let window = resolveWindow(spec, in: content) else {
                throw RecError.windowUnavailable
            }
            let windowSize = window.frame.size // points, window-local
            let scale = screenScale(forTopLeftRect: window.frame)

            // Sub-region in window-local, top-left points; empty => whole window.
            let full = CGRect(origin: .zero, size: windowSize)
            var sourceRect = spec.subRect.isEmpty ? full : spec.subRect.intersection(full)
            if sourceRect.isEmpty { sourceRect = full }

            let config = makeConfig(sourceRect: sourceRect,
                                    pixelWidth: even(Int((sourceRect.width * scale).rounded())),
                                    pixelHeight: even(Int((sourceRect.height * scale).rounded())))
            return (SCContentFilter(desktopIndependentWindow: window), config)
        }
    }

    private func makeConfig(sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(2, pixelWidth)
        config.height = max(2, pixelHeight)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60 fps
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }

    private func resolveWindow(_ spec: WindowSpec, in content: SCShareableContent) -> SCWindow? {
        if let byID = content.windows.first(where: { $0.windowID == spec.windowID }) {
            return byID
        }
        // Fall back to the same app (window IDs don't survive relaunches).
        let sameApp = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == spec.bundleID
        }
        if !spec.title.isEmpty, let byTitle = sameApp.first(where: { ($0.title ?? "") == spec.title }) {
            return byTitle
        }
        return sameApp.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private func screenScale(forTopLeftRect rect: CGRect) -> CGFloat {
        let appKit = Coord.appKit(fromTopLeft: rect)
        let center = CGPoint(x: appKit.midX, y: appKit.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2
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

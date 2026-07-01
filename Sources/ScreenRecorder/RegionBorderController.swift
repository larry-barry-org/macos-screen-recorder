import AppKit

/// A click-through overlay window that draws a dotted border around the
/// selected region. It does NOT dim the screen — the fill is fully clear.
/// While recording, the border is red with animated "marching ants".
final class RegionBorderController {
    private var window: OverlayWindow?
    private let borderView = BorderView()

    func show(region: CGRect, recording: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        borderView.recording = recording
        borderView.startAnimating()
        window.setFrame(region, display: true)
        window.orderFront(nil)
    }

    func update(recording: Bool) {
        borderView.recording = recording
        borderView.needsDisplay = true
    }

    func hide() {
        borderView.stopAnimating()
        window?.orderOut(nil)
    }

    private func makeWindow() -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Keep the border visible on screen but exclude it from screen capture
        // (ScreenCaptureKit honors a window's sharing state).
        window.sharingType = .none
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = borderView
        return window
    }
}

private final class BorderView: NSView {
    var recording = false
    private var dashPhase: CGFloat = 0
    private var timer: Timer?

    override var isFlipped: Bool { false }

    func startAnimating() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dashPhase -= 1.5
            self.needsDisplay = true
        }
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = lineWidth
        path.setLineDash([6, 4], count: 2, phase: dashPhase)
        (recording ? NSColor.systemRed : NSColor.controlAccentColor).setStroke()
        path.stroke()
    }
}

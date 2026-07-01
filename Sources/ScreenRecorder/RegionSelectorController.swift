import AppKit

/// Presents a transparent full-desktop overlay so the user can drag out a
/// capture region. The desktop is NOT dimmed; only the selection rectangle is
/// drawn. Returns the region in global screen coordinates (bottom-left origin).
final class RegionSelectorController {
    private var window: OverlayWindow?
    private var completion: ((CGRect?) -> Void)?

    func begin(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion

        // A single window spanning the union of all displays.
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !unionFrame.isNull else { completion(nil); return }

        let window = OverlayWindow(
            contentRect: unionFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        // A nearly-transparent fill so the overlay reliably hit-tests mouse
        // events across all displays without visibly dimming the screen.
        window.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        window.hasShadow = false
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = SelectionView(frame: NSRect(origin: .zero, size: unionFrame.size))
        view.onFinish = { [weak self] localRect in
            guard let self else { return }
            var result: CGRect?
            if let localRect, localRect.width > 4, localRect.height > 4 {
                // Convert view-local → global by offsetting by the window origin.
                result = localRect.offsetBy(dx: unionFrame.minX, dy: unionFrame.minY)
            }
            self.finish(result)
        }
        window.contentView = view

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(unionFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
    }

    private func finish(_ rect: CGRect?) {
        window?.orderOut(nil)
        window = nil
        completion?(rect)
        completion = nil
    }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(origin: startPoint!, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, p.x),
            y: min(start.y, p.y),
            width: abs(p.x - start.x),
            height: abs(p.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(currentRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onFinish?(nil)
        } else if event.keyCode == 36 { // Return
            onFinish?(currentRect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = currentRect else { return }

        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()

        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        // Live dimensions label.
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let padding: CGFloat = 5
        let boxRect = NSRect(
            x: rect.minX,
            y: rect.maxY + 4,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: boxRect, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: boxRect.minX + padding, y: boxRect.minY + padding / 2), withAttributes: attrs)
    }
}

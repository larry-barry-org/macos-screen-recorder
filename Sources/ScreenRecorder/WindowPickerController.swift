import AppKit
import ScreenCaptureKit

/// Full-desktop overlay to bind a recording to a specific window:
///   Phase 1 — move the mouse to highlight the window under the cursor; click to pick.
///   Phase 2 — drag a sub-region inside that window (or press Return for the whole window).
/// Returns a `WindowSpec` (window id + app + optional window-local crop).
final class WindowPickerController {
    private var window: OverlayWindow?
    private var completion: ((WindowSpec?) -> Void)?

    func begin(completion: @escaping (WindowSpec?) -> Void) {
        self.completion = completion

        Task { @MainActor in
            let windows = await Self.loadWindows()
            guard !windows.isEmpty else { self.finish(nil); return }
            self.present(with: windows)
        }
    }

    @MainActor
    private func present(with windows: [WinInfo]) {
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !unionFrame.isNull else { finish(nil); return }

        let window = OverlayWindow(contentRect: unionFrame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        window.hasShadow = false
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = WindowPickerView(frame: NSRect(origin: .zero, size: unionFrame.size))
        view.unionOrigin = unionFrame.origin
        view.windows = windows
        view.onFinish = { [weak self] spec in self?.finish(spec) }
        window.contentView = view

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(unionFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
    }

    private func finish(_ spec: WindowSpec?) {
        window?.orderOut(nil)
        window = nil
        completion?(spec)
        completion = nil
    }

    // MARK: - Window enumeration

    struct WinInfo {
        let windowID: UInt32
        let bundleID: String
        let title: String
        let label: String
        let appKitRect: CGRect  // global, bottom-left origin
        let topLeftRect: CGRect // global, top-left origin
    }

    /// Front-to-back list of on-screen, normal-layer windows (excluding our own).
    static func loadWindows() async -> [WinInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [WinInfo] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { continue }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let label = title.isEmpty ? ownerName : "\(ownerName) — \(title)"
            result.append(WinInfo(windowID: UInt32(number), bundleID: bundleID, title: title,
                                  label: label,
                                  appKitRect: Coord.appKit(fromTopLeft: bounds),
                                  topLeftRect: bounds))
        }
        return result
    }
}

private final class WindowPickerView: NSView {
    var windows: [WindowPickerController.WinInfo] = []
    var unionOrigin: CGPoint = .zero
    var onFinish: ((WindowSpec?) -> Void)?

    private enum Phase { case pickingWindow, pickingRegion }
    private var phase: Phase = .pickingWindow
    private var hovered: WindowPickerController.WinInfo?
    private var selected: WindowPickerController.WinInfo?
    private var dragStart: NSPoint?
    private var dragRect: NSRect?
    private var ignoreNextMouseUp = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: phase == .pickingWindow ? .arrow : .crosshair)
    }

    /// View-local point -> global AppKit point.
    private func globalPoint(_ event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: local.x + unionOrigin.x, y: local.y + unionOrigin.y)
    }

    /// Topmost window under a global AppKit point.
    private func windowAt(_ p: NSPoint) -> WindowPickerController.WinInfo? {
        windows.first { $0.appKitRect.contains(p) }
    }

    /// Global AppKit rect -> view-local rect.
    private func localRect(_ global: CGRect) -> NSRect {
        NSRect(x: global.minX - unionOrigin.x, y: global.minY - unionOrigin.y,
               width: global.width, height: global.height)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        guard phase == .pickingWindow else { return }
        let hit = windowAt(globalPoint(event))
        if hit?.windowID != hovered?.windowID {
            hovered = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        switch phase {
        case .pickingWindow:
            guard let win = windowAt(globalPoint(event)) else { return }
            selected = win
            phase = .pickingRegion
            // Lock the window on this click; the region drag is a separate
            // gesture, so don't let this click's mouse-up finish the picker.
            ignoreNextMouseUp = true
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        case .pickingRegion:
            dragStart = clampToSelected(convert(event.locationInWindow, from: nil))
            dragRect = NSRect(origin: dragStart!, size: .zero)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase == .pickingRegion, let start = dragStart else { return }
        let p = clampToSelected(convert(event.locationInWindow, from: nil))
        dragRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                          width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if ignoreNextMouseUp { ignoreNextMouseUp = false; return }
        guard phase == .pickingRegion else { return }
        finishRegion()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onFinish?(nil)
        case 36: // Return -> whole window (or current drag if any)
            if phase == .pickingRegion { finishRegion() } else { onFinish?(nil) }
        default:
            break
        }
    }

    /// Constrain a view-local point to the selected window's rect.
    private func clampToSelected(_ p: NSPoint) -> NSPoint {
        guard let win = selected else { return p }
        let r = localRect(win.appKitRect)
        return NSPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }

    private func finishRegion() {
        guard let win = selected else { onFinish?(nil); return }

        var subRect = CGRect.zero // whole window by default
        if let drag = dragRect, drag.width > 4, drag.height > 4 {
            // View-local -> global AppKit -> window-local top-left points.
            let globalRect = CGRect(x: drag.minX + unionOrigin.x, y: drag.minY + unionOrigin.y,
                                    width: drag.width, height: drag.height)
            let topLeft = Coord.topLeft(fromAppKit: globalRect)
            subRect = CGRect(x: topLeft.minX - win.topLeftRect.minX,
                             y: topLeft.minY - win.topLeftRect.minY,
                             width: topLeft.width, height: topLeft.height)
        }
        onFinish?(WindowSpec(windowID: win.windowID, bundleID: win.bundleID,
                             title: win.title, subRect: subRect))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch phase {
        case .pickingWindow:
            guard let win = hovered else { drawHint("Click a window to record it   ·   Esc to cancel"); return }
            let r = localRect(win.appKitRect)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            r.fill()
            let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            drawLabel(win.label, above: r)
            drawHint("Click a window to record it   ·   Esc to cancel")

        case .pickingRegion:
            guard let win = selected else { return }
            let wr = localRect(win.appKitRect)
            // Outline the chosen window.
            let outline = NSBezierPath(rect: wr.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()

            if let drag = dragRect, drag.width > 1 {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                drag.fill()
                let dp = NSBezierPath(rect: drag.insetBy(dx: 0.5, dy: 0.5))
                dp.lineWidth = 1.5
                NSColor.controlAccentColor.setStroke()
                dp.stroke()
            }
            drawHint("Drag a region inside “\(win.label)”   ·   Return = whole window   ·   Esc to cancel")
        }
    }

    private func drawLabel(_ text: String, above rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let box = NSRect(x: rect.minX, y: min(rect.maxY + 4, bounds.maxY - size.height - pad),
                         width: size.width + pad * 2, height: size.height + pad)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 10
        let box = NSRect(x: (bounds.width - size.width) / 2 - pad, y: 40,
                         width: size.width + pad * 2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }
}

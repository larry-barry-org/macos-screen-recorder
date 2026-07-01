import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let recorder = RecordingManager()
    private let border = RegionBorderController()
    private var selector: RegionSelectorController?

    private var uiState: RecState = .idle
    private var region: CGRect? {
        didSet { updateMenu() }
    }

    // Menu items kept as references so we can update titles / enabled state.
    private let startItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let selectItem = NSMenuItem()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        region = RegionStore.load()

        setupStatusItem()
        setupMenu()
        setupHotKeys()

        recorder.onStateChange = { [weak self] state, url in
            self?.handleState(state, url: url)
        }
        recorder.onError = { [weak self] message in
            self?.presentError(message)
        }
        recorder.onFrame = { [weak self] frame in
            self?.updateThumbnail(frame)
        }
    }

    // MARK: - Status item

    private lazy var idleIcon: NSImage = {
        let img = NSImage(systemSymbolName: "film", accessibilityDescription: "Screen Recorder")!
        img.isTemplate = true
        return img
    }()

    private lazy var recordingIcon: NSImage = {
        let base = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!
        let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let img = base.withSymbolConfiguration(cfg) ?? base
        img.isTemplate = false
        return img
    }()

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = idleIcon
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        startItem.title = "Start Recording"
        startItem.target = self
        startItem.action = #selector(toggleRecord)
        startItem.keyEquivalent = "p"
        startItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(startItem)

        pauseItem.title = "Pause Recording"
        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        pauseItem.keyEquivalent = "["
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        selectItem.title = "Select Region…"
        selectItem.target = self
        selectItem.action = #selector(selectRegion)
        menu.addItem(selectItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenu()
    }

    private func updateMenu() {
        let recording = uiState != .idle
        startItem.title = recording ? "Stop Recording" : "Start Recording"
        startItem.isEnabled = recording || (region != nil)

        pauseItem.title = (uiState == .paused) ? "Resume Recording" : "Pause Recording"
        pauseItem.isEnabled = recording

        selectItem.isEnabled = !recording
    }

    // MARK: - Hotkeys

    private func setupHotKeys() {
        // Virtual key codes: p = 35, [ = 33.
        HotKeyCenter.shared.register(id: 1, keyCode: 35, modifiers: HotKeyCenter.Modifiers.commandOption) { [weak self] in
            self?.toggleRecord()
        }
        HotKeyCenter.shared.register(id: 2, keyCode: 33, modifiers: HotKeyCenter.Modifiers.commandOption) { [weak self] in
            self?.togglePause()
        }
    }

    // MARK: - Actions

    @objc private func toggleRecord() {
        if uiState == .idle {
            guard let region else {
                presentError("No region selected. Choose “Select Region…” first.")
                return
            }
            recorder.start(region: region)
        } else {
            recorder.stop()
        }
    }

    @objc private func togglePause() {
        switch uiState {
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        case .idle: break
        }
    }

    @objc private func selectRegion() {
        guard uiState == .idle else { return }
        border.hide()
        // Defer to the next runloop tick so the status-bar menu's modal tracking
        // loop has fully unwound before we present the overlay window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let controller = RegionSelectorController()
            self.selector = controller
            controller.begin { [weak self] rect in
                guard let self else { return }
                if let rect {
                    self.region = rect
                    RegionStore.save(rect)
                }
                self.selector = nil
                self.updateMenu()
            }
        }
    }

    @objc private func quit() {
        if uiState != .idle { recorder.stop() }
        NSApp.terminate(nil)
    }

    // MARK: - State handling

    private func handleState(_ state: RecState, url: URL?) {
        uiState = state
        switch state {
        case .idle:
            statusItem.button?.image = idleIcon
            statusItem.button?.alphaValue = 1
            border.hide()
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }

        case .recording:
            // Shown until the first frame arrives; then live thumbnails take over.
            statusItem.button?.image = recordingIcon
            statusItem.button?.alphaValue = 1
            if let region { border.show(region: region, recording: true) }

        case .paused:
            // Keep the last thumbnail, dimmed, to signal the paused state.
            statusItem.button?.alphaValue = 0.5
        }
        updateMenu()
    }

    // MARK: - Live menu-bar thumbnail

    private func updateThumbnail(_ frame: CGImage) {
        guard uiState == .recording else { return }
        statusItem.button?.image = makeMenuBarImage(from: frame)
        statusItem.button?.alphaValue = 1
    }

    /// Fits the frame into the menu-bar height and overlays a small red dot.
    private func makeMenuBarImage(from cg: CGImage) -> NSImage {
        let maxHeight: CGFloat = 18
        let maxWidth: CGFloat = 46
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(maxHeight / h, maxWidth / w)
        let size = NSSize(width: max(8, (w * scale).rounded()),
                          height: max(8, (h * scale).rounded()))

        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
        NSImage(cgImage: cg, size: size).draw(in: rect)

        let d: CGFloat = 6
        let dotRect = NSRect(x: 2, y: size.height - d - 2, width: d, height: d)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 0.5
        ring.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - Errors

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Screen Recorder"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

import AppKit

/// A borderless window that can still become key/main so it can receive
/// keyboard events (needed for the region selector's Esc / Return handling).
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

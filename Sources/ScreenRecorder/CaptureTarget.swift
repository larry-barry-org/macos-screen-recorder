import AppKit
import CoreGraphics
import Foundation

/// What the recorder captures: either a rectangular region of a display, or a
/// specific window (optionally cropped to a sub-region within it).
enum CaptureTarget: Codable {
    /// Region in global AppKit screen coordinates (bottom-left origin).
    case displayRegion(CGRect)
    case window(WindowSpec)
}

/// Identifies a window to bind to, plus an optional crop within it.
struct WindowSpec: Codable {
    var windowID: UInt32
    var bundleID: String
    var title: String
    /// Window-local crop in points, top-left origin. `.zero` means whole window.
    var subRect: CGRect
}

/// Persists the last-selected capture target in `UserDefaults` as JSON.
enum TargetStore {
    private static let key = "captureTarget"

    static func save(_ target: CaptureTarget) {
        if let data = try? JSONEncoder().encode(target) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> CaptureTarget? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CaptureTarget.self, from: data)
    }
}

/// Converts between AppKit global coordinates (bottom-left origin) and the
/// CoreGraphics / ScreenCaptureKit top-left-origin space used for windows.
/// The flip is an involution, so one formula serves both directions.
enum Coord {
    static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height)
            ?? NSScreen.main?.frame.height ?? 0
    }

    static func appKit(fromTopLeft r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    static func topLeft(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }
}

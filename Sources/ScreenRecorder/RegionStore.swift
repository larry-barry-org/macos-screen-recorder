import Foundation
import CoreGraphics

/// Persists the last-selected capture region in `UserDefaults`.
/// The rect is stored in global screen coordinates (AppKit, bottom-left origin).
enum RegionStore {
    private static let key = "selectedRegion"

    static func save(_ rect: CGRect) {
        UserDefaults.standard.set(
            [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height],
            forKey: key
        )
    }

    static func load() -> CGRect? {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Double],
              a.count == 4 else { return nil }
        let rect = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        return (rect.width > 1 && rect.height > 1) ? rect : nil
    }
}

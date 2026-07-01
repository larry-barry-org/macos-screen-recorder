import SwiftUI

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar; this empty Settings scene
        // just satisfies the App protocol and never shows a window.
        Settings { EmptyView() }
    }
}

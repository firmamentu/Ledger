import SwiftUI

@main
struct LedgerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app has no launch window. AppKit owns the status item and the
        // optional main window; SwiftUI supplies the window content.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

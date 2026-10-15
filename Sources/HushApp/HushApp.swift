import SwiftUI
import HushKit

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { HushSettingsView(state: delegate.state) }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.openSettings() }.keyboardShortcut(",")
                }
                CommandMenu("File") {
                    Button("New meeting") { delegate.state.start() }.keyboardShortcut("n")
                    Button("Open notebook") { delegate.openMain() }.keyboardShortcut("0")
                    Divider()
                    Button("Close") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
                }
            }
    }
}

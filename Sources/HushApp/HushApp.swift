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
                CommandMenu("Edit") {
                    Button("Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }.keyboardShortcut("z")
                    Divider()
                    Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
                    Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.keyboardShortcut("c")
                    Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.keyboardShortcut("v")
                    Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
                }
            }
    }
}

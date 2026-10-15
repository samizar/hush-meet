import AppKit
import EventKit
import QuartzCore
import SwiftUI
import UserNotifications
import HushKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var meetingPanel: NSPanel?
    private var cardTask: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if state.isDemo && ProcessInfo.processInfo.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.toolTip = "Hush — meeting notes"
        updateStatus(false)
        popover.behavior = .transient; popover.contentViewController = NSHostingController(rootView: PopoverView(state: state).hushEnvironment())
        state.showMain = { [weak self] in self?.openMain() }
        state.showSettings = { [weak self] in self?.openSettings() }
        state.showCard = { [weak self] event, app in self?.presentCard(event, app: app) }
        state.dismissCard = { [weak self] in self?.hideCard() }
        state.recordingChanged = { [weak self] recording in self?.updateStatus(recording) }
        state.updater = AppUpdater(isDemo: state.isDemo, isBusy: { [weak self] in self?.state.preventsUpdateRestart ?? true })
        if !state.isDemo {
            let center = UNUserNotificationCenter.current(); center.delegate = self
            let record = UNNotificationAction(identifier: "RECORD", title: "Record", options: [.foreground])
            let skip = UNNotificationAction(identifier: "SKIP", title: "Skip", options: [])
            center.setNotificationCategories([UNNotificationCategory(identifier: "MEETING", actions: [record, skip], intentIdentifiers: [])])
            observations.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.state.calendar.refresh(); self?.state.scheduleNotifications() }
            })
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.state.preferences.calendarEnabled == true { self?.state.calendar.refresh(); self?.state.scheduleNotifications() } }
            })
        }
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.updateStatus(self.state.capture.isRecording) }
        })
        Task {
            await state.load()
            state.updater?.start()
            if state.isDemo { openMain() }
            else if !state.preferences.onboardingCompleted { openOnboarding() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !state.hasActiveMeetingWork {
            guard !state.sideNotesSaving.isEmpty || !state.sideNotesSaveErrors.isEmpty else { return .terminateNow }
            Task {
                let saved = await state.flushSideNotes()
                if !saved { state.notice = "Your side notes couldn't be saved. Keep Hush open and try saving them again."; openMain() }
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        let alert = NSAlert(); alert.messageText = "Hush is still working"
        alert.informativeText = "Stop the recording and wait for notes to finish before quitting."
        alert.addButton(withTitle: "Keep Hush open"); alert.runModal()
        return .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openMain(); return true }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow { mainWindow = nil }
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil }
        if notification.object as? NSWindow === onboardingWindow { onboardingWindow = nil }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    @objc private func newMeeting() { state.start() }
    @objc private func showNotebook() { openMain() }
    @objc private func showPreferences() { openSettings() }
    func openMain() {
        popover.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DesignTokens.windowWidth, height: DesignTokens.windowHeight),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Hush"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(DesignTokens.paper); window.isReleasedWhenClosed = false; window.delegate = self
            window.minSize = NSSize(width: DesignTokens.minWindowWidth, height: DesignTokens.minWindowHeight)
            window.contentView = NSHostingView(rootView: NotebookView(state: state).hushEnvironment())
            window.setFrameAutosaveName(state.isDemo ? "HushPreview" : "HushNotebook"); window.center(); mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DesignTokens.settingsWidth, height: DesignTokens.settingsHeight),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Hush Settings"; window.backgroundColor = NSColor(DesignTokens.paper); window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: HushSettingsView(state: state).hushEnvironment()); window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func openOnboarding() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DesignTokens.onboardingWidth, height: DesignTokens.onboardingHeight),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Hush"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.backgroundColor = NSColor(DesignTokens.paper); window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(state: state) { [weak self] in self?.onboardingWindow?.close(); self?.openMain() }.hushEnvironment())
        window.center(); onboardingWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func updateStatus(_ recording: Bool) {
        guard let button = statusItem?.button else { return }
        let size = NSSize(width: DesignTokens.icon, height: DesignTokens.icon)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: DesignTokens.divider, dy: DesignTokens.divider))
            if recording { NSColor(DesignTokens.ember).setFill(); circle.fill() }
            else { NSColor.labelColor.setStroke(); circle.lineWidth = DesignTokens.lineWidth; circle.stroke() }
            return true
        }
        image.isTemplate = !recording; button.image = image
        button.wantsLayer = true; button.layer?.removeAnimation(forKey: "breathing")
        if recording && !DesignTokens.reduceMotion {
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = 1; animation.toValue = DesignTokens.breathScale
            animation.duration = DesignTokens.breathDuration / 2; animation.autoreverses = true; animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); button.layer?.add(animation, forKey: "breathing")
        }
        button.toolTip = recording ? "Hush — Listening. Click to stop." : "Hush — meeting notes"
    }
    private func presentCard(_ event: CalendarMeeting?, app: String?) {
        hideCard()
        guard let button = statusItem.button, let statusWindow = button.window else { return }
        let controller = NSHostingController(rootView: MeetingCardView(state: state, event: event, app: app).hushEnvironment())
        let size = controller.view.fittingSize
        let rect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = statusWindow.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let panel = MeetingPanel(contentRect: NSRect(x: min(max(rect.midX - size.width / 2, screen.minX + DesignTokens.space), screen.maxX - size.width - DesignTokens.space),
            y: rect.minY - size.height - DesignTokens.space, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.contentViewController = controller
        let destination = panel.frame
        if !DesignTokens.reduceMotion { panel.setFrameOrigin(NSPoint(x: destination.origin.x, y: destination.origin.y + DesignTokens.space)) }
        panel.alphaValue = 0; panel.orderFrontRegardless(); meetingPanel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22; panel.animator().alphaValue = 1; panel.animator().setFrame(destination, display: true)
        }
        cardTask = Task { try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }; hideCard() }
    }
    private func hideCard() { cardTask?.cancel(); cardTask = nil; meetingPanel?.orderOut(nil); meetingPanel = nil }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let eventID = response.notification.request.content.userInfo["event"] as? String
        let meetingID = response.notification.request.content.userInfo["meeting"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            if let meetingID, let id = UUID(uuidString: meetingID) { state.select(id); openMain() }
            else if let eventID, let event = state.calendar.meetings.first(where: { $0.id == eventID }) {
                if action == "RECORD" { state.start(event: event) }
                else if action == "SKIP" { state.skip(event) }
                else { presentCard(event, app: nil) }
            }
        }
        completionHandler()
    }
}

private final class MeetingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import AppKit
import EventKit
import QuartzCore
import SwiftUI
import UserNotifications
import HushKit
import MuesliCore

@MainActor @Observable
final class SettingsRouter { var tab: SettingsTab = .general }

private struct SettingsHost: View {
    @Bindable var state: AppState
    @Bindable var router: SettingsRouter
    var body: some View { HushSettingsView(state: state, tab: $router.tab) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let state = AppState()
    private let settingsRouter = SettingsRouter()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var meetingPanel: NSPanel?
    private var cardTask: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private var hotKey: HotKey?
    private var lastStatus: (recording: Bool, title: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if state.isDemo && ProcessInfo.processInfo.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityLabel("Hush")
        updateStatus()
        popover.behavior = .transient; popover.animates = !DesignTokens.reduceMotion
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: state).hushEnvironment())
        state.showMain = { [weak self] in self?.openMain() }
        state.showSettings = { [weak self] tab in self?.openSettings(tab) }
        state.showCard = { [weak self] event, app in self?.presentCard(event, app: app) }
        state.dismissCard = { [weak self] in self?.hideCard() }
        state.recordingChanged = { [weak self] _ in self?.updateStatus() }
        state.updater = AppUpdater(isDemo: state.isDemo, isBusy: { [weak self] in self?.state.preventsUpdateRestart ?? true })
        if !state.isDemo {
            let center = UNUserNotificationCenter.current(); center.delegate = self
            let join = UNNotificationAction(identifier: "JOIN", title: "Join & record", options: [.foreground])
            let record = UNNotificationAction(identifier: "RECORD", title: "Record", options: [.foreground])
            let skip = UNNotificationAction(identifier: "SKIP", title: "Not now", options: [])
            center.setNotificationCategories([UNNotificationCategory(identifier: "MEETING", actions: [join, record, skip], intentIdentifiers: [])])
            observations.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.state.calendar.refresh(); self?.state.scheduleNotifications() }
            })
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.state.preferences.calendarEnabled == true { self?.state.calendar.refresh(); self?.state.scheduleNotifications() } }
            })
            // Audio devices stop when the Mac sleeps. Finish the recording cleanly instead of losing its end.
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state.capture.isRecording else { return }
                    DiagnosticLog.shared.record(.stoppedForSleep)
                    self.state.stop(reason: "Recording stopped because your Mac went to sleep. Your notes are being written.")
                }
            })
        }
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastStatus = nil; self?.updateStatus() }
        })
        observePreferences()
        Task {
            await state.load()
            state.updater?.start()
            if state.isDemo { openDemo() }
            else if !state.preferences.onboardingCompleted { openOnboarding() }
        }
    }

    /// `--demo-open tasks|transcript|popover|card|onboarding|settings:<tab>` opens one surface for review.
    private func openDemo() {
        let arguments = ProcessInfo.processInfo.arguments
        let target = arguments.firstIndex(of: "--demo-open").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "home"
        switch target {
        case "tasks": state.go(.tasks); openMain()
        case "transcript":
            if let first = state.meetings.first { state.select(first.id) }
            state.meetingTab = .transcript; openMain()
        case "popover": openMain(); Task { try? await Task.sleep(for: .milliseconds(400)); togglePopover() }
        case "card": presentCard(state.calendar.meetings.first, app: nil)
        case "onboarding": openOnboarding()
        case "recording": openMain(); state.start()
        case let value where value.hasPrefix("settings"):
            openSettings(SettingsTab(rawValue: value.components(separatedBy: ":").last ?? "") ?? .general)
        default: openMain()
        }
    }

    /// Keeps the shortcut, menu bar timer and Dock presence in step with preferences and recording state.
    private func observePreferences() {
        withObservationTracking {
            _ = state.preferences.globalShortcut; _ = state.preferences.menuBarTimer; _ = state.preferences.showInDock
            _ = state.capture.isRecording; _ = Int(state.elapsed); _ = state.busy
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyPreferences(); self?.observePreferences() }
        }
        applyPreferences()
    }
    private func applyPreferences() {
        if state.preferences.globalShortcut && !state.isDemo {
            if hotKey == nil { hotKey = HotKey { [weak self] in self?.state.toggleRecording() } }
        } else { hotKey?.unregister(); hotKey = nil }
        updateStatus()
        updateActivationPolicy()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.capture.isRecording || state.isStopping || state.isStarting {
            let alert = NSAlert(); alert.messageText = "Stop recording and quit?"
            alert.informativeText = "Hush saves what it has heard so far. The notes are written the next time you open Hush."
            alert.addButton(withTitle: "Stop and Quit"); alert.addButton(withTitle: "Keep Recording")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            state.stop()
            Task {
                while state.isStopping || state.capture.isRecording { try? await Task.sleep(for: .milliseconds(100)) }
                state.cancelProcessing()
                let saved = await state.flushWrites()
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        if state.activeJob != nil || !state.queue.isEmpty {
            let alert = NSAlert(); alert.messageText = "Hush is still writing notes"
            alert.informativeText = state.preferences.providers.leavesMac
                ? "If you quit now, you can finish them later with Try again."
                : "If you quit now, Hush finishes them the next time it opens."
            alert.addButton(withTitle: "Quit Anyway"); alert.addButton(withTitle: "Keep Hush Open")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        guard !state.savingIDs.isEmpty || !state.saveErrors.isEmpty else { return .terminateNow }
        Task {
            let saved = await state.flushWrites()
            if !saved { state.show(.error, "Your side notes couldn't be saved", detail: "Keep Hush open and try saving them again."); openMain() }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openMain(); return true }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow { mainWindow = nil }
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil }
        if notification.object as? NSWindow === onboardingWindow { onboardingWindow = nil }
        Task { @MainActor in self.updateActivationPolicy() }
    }

    // MARK: Windows

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func openMain() {
        popover.performClose(nil)
        if mainWindow == nil {
            let controller = NSHostingController(rootView: NotebookView(state: state).hushEnvironment())
            controller.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: DesignTokens.windowWidth, height: DesignTokens.windowHeight))
            window.title = "Hush"; window.toolbarStyle = .unified; window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(DesignTokens.paper); window.isReleasedWhenClosed = false; window.delegate = self
            window.contentMinSize = NSSize(width: DesignTokens.minWindowWidth, height: DesignTokens.minWindowHeight)
            window.tabbingMode = .disallowed
            window.setFrameAutosaveName(state.isDemo ? "HushPreview3" : "HushNotebook2")
            if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
            mainWindow = window
            // Don't start with the cursor in a search or text field; arrow keys should move through meetings.
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
        updateActivationPolicy(forceRegular: true)
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func openSettings(_ tab: SettingsTab? = nil) {
        popover.performClose(nil)
        if let tab { settingsRouter.tab = tab }
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsHost(state: state, router: settingsRouter).hushEnvironment())
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: DesignTokens.settingsWidth, height: DesignTokens.settingsHeight))
            window.title = "Hush Settings"; window.toolbarStyle = .unified; window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.backgroundColor = NSColor(DesignTokens.paper); window.isReleasedWhenClosed = false; window.delegate = self
            window.tabbingMode = .disallowed
            window.setFrameAutosaveName("HushSettings2")
            if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
            settingsWindow = window
        }
        updateActivationPolicy(forceRegular: true)
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func openOnboarding() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DesignTokens.onboardingWidth, height: DesignTokens.onboardingHeight),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Hush"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.backgroundColor = NSColor(DesignTokens.paper); window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(state: state) { [weak self] record in
            self?.onboardingWindow?.close()
            self?.openMain()
            if record { self?.state.start() }
        }.hushEnvironment())
        window.center(); onboardingWindow = window
        updateActivationPolicy(forceRegular: true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    /// A Dock icon and app switcher entry while a window is open; menu bar only otherwise.
    private func updateActivationPolicy(forceRegular: Bool = false) {
        let windowOpen = forceRegular || [mainWindow, settingsWindow, onboardingWindow].contains { $0?.isVisible == true }
        let wanted: NSApplication.ActivationPolicy = windowOpen && state.preferences.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Menu bar item

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let recording = state.capture.isRecording
        let title = recording && state.preferences.menuBarTimer ? " " + Transcript.timestamp(state.elapsed) : ""
        if let lastStatus, lastStatus.recording == recording, lastStatus.title == title { return }
        let changedState = lastStatus?.recording != recording
        lastStatus = (recording, title)
        if changedState || button.image == nil {
            let size = NSSize(width: DesignTokens.icon, height: DesignTokens.icon)
            let image = NSImage(size: size, flipped: false) { rect in
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                if recording { NSColor(DesignTokens.ember).setFill(); circle.fill() }
                else { NSColor.labelColor.setStroke(); circle.lineWidth = DesignTokens.lineWidth; circle.stroke() }
                return true
            }
            image.isTemplate = !recording; button.image = image
            button.wantsLayer = true; button.layer?.removeAnimation(forKey: "breathing")
            if recording && !DesignTokens.reduceMotion && title.isEmpty {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1; animation.toValue = 0.55
                animation.duration = DesignTokens.breathDuration / 2; animation.autoreverses = true; animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); button.layer?.add(animation, forKey: "breathing")
            }
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        button.toolTip = recording ? "Hush is listening. Click to see the meeting." : state.busy ? "Hush is writing notes." : "Hush"
    }

    // MARK: Meeting card

    private func presentCard(_ event: CalendarMeeting?, app: String?) {
        hideCard()
        guard let button = statusItem.button, let statusWindow = button.window else { return }
        let controller = NSHostingController(rootView: MeetingCardView(state: state, event: event, app: app).hushEnvironment())
        let size = controller.view.fittingSize
        let rect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = statusWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panel = MeetingPanel(contentRect: NSRect(x: min(max(rect.midX - size.width / 2, screen.minX), screen.maxX - size.width),
            y: rect.minY - size.height, width: size.width, height: size.height),
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
        cardTask = Task { try? await Task.sleep(for: .seconds(45)); guard !Task.isCancelled else { return }; hideCard() }
    }
    private func hideCard() {
        cardTask?.cancel(); cardTask = nil
        guard let panel = meetingPanel else { return }
        meetingPanel = nil
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.18; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let eventID = response.notification.request.content.userInfo["event"] as? String
        let meetingID = response.notification.request.content.userInfo["meeting"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            if let meetingID, let id = UUID(uuidString: meetingID) { state.select(id); openMain() }
            else if let eventID, let event = state.calendar.meetings.first(where: { $0.id == eventID }) {
                switch action {
                case "JOIN": state.join(event)
                case "RECORD": state.start(event: event)
                case "SKIP": state.skip(event)
                default: presentCard(event, app: nil)
                }
            }
        }
        completionHandler()
    }
}

private final class MeetingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

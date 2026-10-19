import SwiftUI
import UserNotifications
import ServiceManagement
import HushKit
import MuesliCore
import MuesliTranscribe

struct HushSettingsView: View {
    @Bindable var state: AppState
    @Binding var tab: SettingsTab
    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { tab }, set: { if let value = $0 { tab = value } })) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch tab {
                case .general: GeneralSettings(state: state)
                case .recording: RecordingSettings(state: state)
                case .models: ModelSettings(state: state)
                case .templates: TemplateSettings(state: state)
                case .privacy: PrivacySettings(state: state)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).background(DesignTokens.paper)
            .overlay(alignment: .top) { BannerStack(state: state, compact: true).frame(maxWidth: 440).padding(.top, DesignTokens.gap) }
            .navigationTitle(tab.title)
        }
        .tint(DesignTokens.ink)
    }
}

// MARK: General

struct GeneralSettings: View {
    @Bindable var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section {
                Toggle("Open Hush at login", isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = $0; state.setLaunchAtLogin($0) }))
                Toggle("Show in the Dock while a Hush window is open", isOn: $state.preferences.showInDock)
                Toggle("Show recording time in the menu bar", isOn: $state.preferences.menuBarTimer)
                Toggle(isOn: $state.preferences.globalShortcut) {
                    HStack { Text("Start and stop recording from anywhere"); Spacer(); KeyHint("⌃⌥⌘R") }
                }
            }
            Section("Updates") {
                if let updater = state.updater, !state.isDemo {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                    Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticInstallation }, set: { updater.setAutomaticInstallation($0) }))
                        .disabled(!updater.automaticChecks)
                    LabeledContent {
                        Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheck || state.preventsUpdateRestart)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed updates install when Hush quits, never during a meeting.")
                            if let status = updater.status { Text(status).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
                            else if let date = updater.lastChecked { Text("Last checked " + date.formatted(.relative(presentation: .named))).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
                        }
                    }
                } else { Text("Updates are off in preview mode.").foregroundStyle(DesignTokens.soft) }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0")
                Text("Update checks contact GitHub. Meeting content and API keys are never included.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
        }
    }
}

// MARK: Recording

struct RecordingSettings: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            Section {
                LanguagePicker(locale: $state.preferences.locale, locales: state.locales)
                Toggle("Delete audio after transcription", isOn: $state.preferences.deleteAudio)
                Text(state.preferences.deleteAudio ? "Transcripts and notes stay. The two audio tracks are removed once the transcript is final." : "Audio is kept with each meeting, so you can play it back from the transcript.")
                    .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                Toggle("Copy a consent line when recording starts", isOn: $state.preferences.copyConsent)
                if state.preferences.copyConsent { Text("“I'm taking notes with Hush.”").font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
            }
            Section("Calendar") {
                if state.calendar.hasAccess || state.isDemo {
                    Toggle("Use Apple Calendar", isOn: $state.preferences.calendarEnabled).onChange(of: state.preferences.calendarEnabled) {
                        if state.preferences.calendarEnabled { state.calendar.refresh(); state.scheduleNotifications() }
                        else { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
                    }
                    Toggle("Remind me a minute before meetings", isOn: $state.preferences.meetingReminders)
                        .disabled(!state.preferences.calendarEnabled)
                        .onChange(of: state.preferences.meetingReminders) { state.scheduleNotifications() }
                    Toggle("Start recording when a meeting begins", isOn: $state.preferences.autoRecord)
                        .disabled(!state.preferences.calendarEnabled)
                    Text("Your first recording and cloud providers always ask first. Change single meetings from Home.")
                        .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                } else {
                    LabeledContent {
                        Button("Connect Calendar", action: state.enableCalendar)
                    } label: {
                        Text("Google, Outlook and iCloud calendars you've added to macOS appear here. Read-only.")
                    }
                }
            }
            Section("Calls") {
                Toggle("Offer to record when a call starts", isOn: $state.preferences.detectCalls)
                Text("Unscheduled calls always ask. Recording stops a minute after the call app releases its microphone.")
                    .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
            Section("Other side of the call") {
                Picker("Record audio from", selection: $state.preferences.captureAllApps) {
                    Text("Call apps only").tag(false)
                    Text("Everything the Mac plays").tag(true)
                }
                if !state.preferences.captureAllApps {
                    ForEach(Self.callApps, id: \.id) { app in
                        Toggle(app.name, isOn: Binding(get: { state.preferences.captureApps.contains(app.id) }, set: { enabled in
                            if enabled { state.preferences.captureApps.append(app.id) }
                            else { state.preferences.captureApps.removeAll { $0 == app.id } }
                        }))
                    }
                }
                Text("A browser includes audio from all of its tabs. Keep music in another app while recording.")
                    .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                LabeledContent("Permission") {
                    Button("Screen & System Audio Recording…") { NSWorkspace.shared.open(CaptureSession.systemAudioSettings) }
                }
            }
        }
        .disabled(state.capture.isRecording)
    }
    static let callApps = [
        (id: "us.zoom.xos", name: "Zoom"), (id: "com.microsoft.teams2", name: "Microsoft Teams"),
        (id: "com.google.Chrome", name: "Google Chrome"), (id: "com.apple.Safari", name: "Safari"),
        (id: "com.apple.FaceTime", name: "FaceTime"), (id: "com.tinyspeck.slackmacgap", name: "Slack"),
        (id: "org.mozilla.firefox", name: "Firefox"), (id: "com.microsoft.edgemac", name: "Microsoft Edge"),
        (id: "company.thebrowser.Browser", name: "Arc"), (id: "com.cisco.webexmeetingsapp", name: "Webex"),
        (id: "com.hnc.Discord", name: "Discord")
    ]
}

// MARK: Models

struct ModelSettings: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: DesignTokens.gap) {
                    Image(systemName: state.preferences.providers.leavesMac ? "arrow.up.forward.circle" : "lock.fill")
                        .font(.system(size: 18)).foregroundStyle(state.preferences.providers.leavesMac ? DesignTokens.amber : DesignTokens.sage)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.preferences.providers.leavesMac ? "Some meeting data leaves this Mac" : "Everything stays on this Mac").font(DesignTokens.chromeStrong)
                        Text(state.preferences.providers.dataFlow).font(DesignTokens.small).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 4)
            }
            if state.capture.isRecording || state.busy {
                Section {
                    Text(state.capture.isRecording ? "Changes apply to your next recording." : "Hush is writing notes. Changes apply to the next meeting.")
                        .foregroundStyle(DesignTokens.soft)
                }
            }
            Section("Transcription") {
                Picker("Provider", selection: $state.preferences.providers.transcription) {
                    ForEach(TranscriptionService.allCases) { Text($0.name + ($0 == .apple ? " — on this Mac" : "")).tag($0) }
                }
                if state.preferences.providers.transcription == .apple {
                    Text("Free and private. Words appear live while you record.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    ModelTestButton(title: "Check this language") {
                        let identifier = state.preferences.locale
                        return {
                            _ = try await StreamTranscriber.prepare(locale: Locale(identifier: identifier))
                            return "Apple Speech is ready for \(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)."
                        }
                    }
                } else {
                    ProviderKeyRow(account: state.preferences.providers.transcription.rawValue, name: state.preferences.providers.transcription.name) {
                        _ = try await CloudTranscriptionProvider(service: state.preferences.providers.transcription).transcribe(
                            wav: WaveAudio.encode(samples: Data(repeating: 0, count: 32_000)), locale: state.preferences.locale)
                    }.id("speech-" + state.preferences.providers.transcription.rawValue)
                    Text("Transcribed after you stop. A test sends one second of silence and may be billed.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                }
            }.disabled(state.capture.isRecording)
            Section("Notes") {
                Picker("Provider", selection: $state.preferences.providers.notes) {
                    ForEach(NotesService.allCases) { Text($0.name).tag($0) }
                }.onChange(of: state.preferences.providers.notes) {
                    state.preferences.providers.model = ""; state.preferences.providers.localURL = nil
                }
                if state.preferences.providers.notes == .apple {
                    Text(AppleNotesProvider.unavailableReason ?? "Ready. Notes are written entirely on this Mac.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    ModelTestButton(title: "Test on-device notes") {
                        return {
                            let result = try await AppleNotesProvider().generate(
                                system: "Write brief meeting notes using the supplied schema. Include only facts stated in the example.",
                                user: "This is a model test. We agreed to meet on Friday. Sam will send the agenda tomorrow.")
                            guard !result.notes.summary.isEmpty else { throw HushError.message("The notes model returned an empty result. Try again.") }
                            return "Works. Notes were written on this Mac from a short example."
                        }
                    }
                } else if state.preferences.providers.notes.isLocalServer {
                    LocalModelSettings(configuration: $state.preferences.providers).id(state.preferences.providers.notes)
                } else {
                    TextField("Model", text: $state.preferences.providers.model, prompt: Text(state.preferences.providers.notes.defaultModel))
                    if state.preferences.providers.notes == .compatible {
                        TextField("HTTPS base URL", text: $state.preferences.providers.compatibleURL)
                        Text("Remote servers need a valid HTTPS address. For a server on this Mac, choose Ollama or LM Studio above.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    }
                    ProviderKeyRow(account: state.preferences.providers.notes.rawValue, name: state.preferences.providers.notes.name,
                                   optional: state.preferences.providers.notes == .compatible) {
                        let provider = CloudNotesProvider(configuration: state.preferences.providers)
                        _ = try await provider.generate(system: "Return meeting notes using the supplied schema. No action items unless stated.", user: "Test meeting: We agreed to meet on Friday. This is a connection test.")
                    }.id("notes-" + state.preferences.providers.notes.rawValue)
                    Text("A test sends a short example and may be billed.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                }
            }.disabled(state.capture.isRecording)
        }
    }
}

// MARK: Privacy

struct PrivacySettings: View {
    @Bindable var state: AppState
    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Meetings") {
                    Text("\(state.meetings.count) · " + ByteCountFormatter.string(fromByteCount: state.storageSize, countStyle: .file)).monospacedDigit()
                }
                LabeledContent("Location") {
                    Text(state.storageURL.path(percentEncoded: false)).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(state.storageURL) }
                    Button("Move to Another Folder…", action: state.chooseStorage).disabled(state.busy || state.capture.isRecording || state.isDemo)
                }
                Toggle(isOn: Binding(get: { state.preferences.encrypted }, set: { state.setEncryption($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Encrypt saved meetings")
                        Text("AES-GCM with a key in this Mac's Keychain. Keep the Keychain item: without it, encrypted meetings can't be opened.")
                            .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    }
                }.disabled(state.busy || state.capture.isRecording || state.isDemo)
            }
            Section("What Hush does and doesn't do") {
                promise("lock", "No account, server, analytics or crash reporting.")
                promise("cpu", "Apple's speech and notes models run on this Mac by default. Local model servers stay on loopback addresses.")
                promise("arrow.up.forward.circle", "Cloud providers run only when you choose them, and Hush asks before each meeting. Never a silent fallback.")
                promise("key", "API keys live in the Keychain, never in meeting files or logs.")
                promise("magnifyingglass", "Search runs in memory and is rebuilt from your files.")
                promise("calendar", "Calendar access is read-only. Reminders are added only when you ask.")
                promise("arrow.down.circle", "Apple may download its models once. Update checks contact GitHub.")
            }
            Section("Troubleshooting") {
                Text("Diagnostic logs record processing steps and error numbers only — no meeting content, audio or keys. They never leave this Mac.")
                    .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                Button("Open Diagnostic Logs") {
                    try? FileManager.default.createDirectory(at: DiagnosticLog.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    NSWorkspace.shared.open(DiagnosticLog.directory)
                }
            }
            Section {
                Button("Delete All Meetings…", role: .destructive, action: state.deleteAll).disabled(state.busy || state.capture.isRecording || state.meetings.isEmpty)
            }
        }
    }
    private func promise(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(DesignTokens.soft) }
    }
}

// MARK: Shared controls

struct ModelTestButton: View {
    let title: String
    var limit: Duration = .seconds(60)
    var operation: () -> @Sendable () async throws -> String
    @State private var testing = false
    @State private var message: String?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            HStack {
                Button(testing ? "Testing…" : title) {
                    let check = operation()
                    testing = true; message = nil
                    DiagnosticLog.shared.record(.modelCheckStarted)
                    Task {
                        defer { testing = false }
                        do {
                            message = try await AsyncDeadline.run(for: limit, operation: check); failed = false
                            DiagnosticLog.shared.record(.modelCheckFinished)
                        } catch {
                            failed = true
                            message = error is AsyncDeadline.TimedOut ? "The test took too long. Check that the model is ready, then try again." : error.localizedDescription
                            DiagnosticLog.shared.record(.modelCheckFailed, error: error)
                        }
                    }
                }.disabled(testing)
                if testing { ProgressView().controlSize(.small).accessibilityLabel("Testing model") }
            }
            if let message {
                Label(message, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(DesignTokens.small).foregroundStyle(failed ? DesignTokens.ember : DesignTokens.sage).textSelection(.enabled)
            }
        }
    }
}

struct ProviderKeyRow: View {
    var account: String
    var name: String
    var optional = false
    var test: () async throws -> Void
    @State private var key = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var message: String?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            SecureField(hasKey ? "Key saved in Keychain" : optional ? "API key (optional)" : "\(name) API key", text: $key)
                .textFieldStyle(.roundedBorder).accessibilityLabel(name + " API key")
            HStack {
                Button("Save Key") { save() }.disabled(key.isEmpty || testing)
                Button(testing ? "Testing…" : "Test Connection") {
                    if !key.isEmpty && !save() { return }
                    testing = true; message = nil
                    Task {
                        do { try await test(); message = "Connection works."; failed = false }
                        catch { message = error.localizedDescription; failed = true }
                        testing = false
                    }
                }.disabled(testing || (!hasKey && key.isEmpty && !optional))
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                if hasKey { Button("Remove Key") { do { try Secrets.remove(account); hasKey = false; message = "Key removed."; failed = false } catch { message = error.localizedDescription; failed = true } }.disabled(testing) }
            }
            if let message { Text(message).font(DesignTokens.small).foregroundStyle(failed ? DesignTokens.ember : DesignTokens.soft) }
        }.onAppear { do { hasKey = try Secrets.get(account) != nil } catch { message = error.localizedDescription } }
    }
    @discardableResult private func save() -> Bool {
        do { try Secrets.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: account); key = ""; hasKey = true; message = "Saved in Keychain."; failed = false; return true }
        catch { message = error.localizedDescription; failed = true; return false }
    }
}

struct LanguagePicker: View {
    @Binding var locale: String
    var locales: [Locale]
    private var choices: [Locale] {
        let common = ["en-US", "en-GB", "fi-FI", "sv-SE", "es-ES", "fr-FR", "de-DE", "ar-SA", "pt-BR", "zh-CN", "ja-JP", "ko-KR", "hi-IN", "it-IT", "nl-NL", "uk-UA"]
        return Array(Set((locales.map(\.identifier) + common + [locale]).map { $0.replacingOccurrences(of: "_", with: "-") })).sorted {
            (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
        }.map { Locale(identifier: $0) }
    }
    var body: some View {
        Picker("Spoken language", selection: Binding(get: { locale.replacingOccurrences(of: "_", with: "-") }, set: { locale = $0 })) {
            ForEach(choices, id: \.identifier) { language in
                Text(Locale.current.localizedString(forIdentifier: language.identifier) ?? language.identifier).tag(language.identifier)
            }
        }
    }
}

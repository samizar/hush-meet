import SwiftUI
import UserNotifications
import ServiceManagement
import HushKit
import MuesliTranscribe

struct HushSettingsView: View {
    @Bindable var state: AppState
    @State private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            meetings.tabItem { Label("Meetings", systemImage: "calendar") }.tag("meetings")
            models.tabItem { Label("Models", systemImage: "slider.horizontal.3") }.tag("models")
            privacy.tabItem { Label("Privacy", systemImage: "lock") }.tag("privacy")
        }.padding(DesignTokens.inset).font(DesignTokens.chrome).tint(DesignTokens.ink)
            .foregroundStyle(DesignTokens.ink).background(DesignTokens.paper)
            .frame(width: DesignTokens.settingsWidth, height: DesignTokens.settingsHeight)
    }
    private var general: some View {
        Form {
            Section {
                Toggle("Launch Hush at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { state.setLaunchAtLogin($0) }))
                Toggle("Delete audio after transcription", isOn: $state.preferences.deleteAudio)
                Text("Your transcript and notes stay. The two audio tracks are temporary.").foregroundStyle(DesignTokens.soft)
                Toggle("Copy a consent reminder when recording starts", isOn: $state.preferences.copyConsent)
                Text("“I'm taking notes with Hush.”").font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
            }
            Section("Storage") {
                Text(state.storageURL.path(percentEncoded: false)).font(DesignTokens.small).foregroundStyle(DesignTokens.soft).textSelection(.enabled)
                HStack {
                    Button("Choose folder…", action: state.chooseStorage).disabled(state.busy || state.capture.isRecording)
                    Button("Reveal in Finder") { NSWorkspace.shared.open(state.storageURL) }
                }
            }
            Section("Templates") {
                Text("Each template is a Markdown file. Duplicate one, edit its instructions and layout, then choose it for a meeting.").foregroundStyle(DesignTokens.soft)
                HStack {
                    Button("Open templates folder") { NSWorkspace.shared.open(Templates.directory) }
                    Menu("Duplicate template") {
                        ForEach(state.templates) { template in
                            Button(template.name) {
                                do { let url = try Templates.duplicate(template); state.templates = try Templates.load(); NSWorkspace.shared.open(url) }
                                catch { state.notice = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            Section("Updates") {
                if let updater = state.updater, !state.isDemo {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                    Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticInstallation }, set: { updater.setAutomaticInstallation($0) }))
                        .disabled(!updater.automaticChecks)
                    Text("Checks daily. Signed updates install when Hush quits. Recordings and notes are never interrupted.")
                        .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    HStack {
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck || state.preventsUpdateRestart)
                        if let date = updater.lastChecked { Text(date, format: .dateTime.month().day().hour().minute()).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
                    }
                    if let status = updater.status { Text(status).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
                    Text("Update checks contact GitHub. Meeting content and API keys are never included.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                } else { Text("Updates are disabled in preview mode.").foregroundStyle(DesignTokens.soft) }
                Text("Hush \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0")")
                    .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
            settingsNotice
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    private var meetings: some View {
        Form {
            Section {
                Toggle("Start recording automatically when a meeting begins", isOn: $state.preferences.autoRecord)
                Text("Off by default. Cloud providers and first recordings always ask. Override individual meetings in the upcoming list.").foregroundStyle(DesignTokens.soft)
                Toggle("Offer to record when a call is detected", isOn: $state.preferences.detectCalls)
                Text("Unscheduled calls always ask before recording. Hush stops after a call releases its microphone for one minute.").foregroundStyle(DesignTokens.soft)
            }
            Section("Calendar") {
                if state.calendar.hasAccess {
                    Toggle("Use Apple Calendar", isOn: $state.preferences.calendarEnabled).onChange(of: state.preferences.calendarEnabled) {
                        if state.preferences.calendarEnabled { state.calendar.refresh(); state.scheduleNotifications() }
                        else { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
                    }
                    Text("Google, Outlook and iCloud events appear through the accounts you've added to macOS.").foregroundStyle(DesignTokens.soft)
                } else { Button("Allow calendar access", action: state.enableCalendar) }
            }
            Section("System audio") {
                Toggle("Capture all apps", isOn: $state.preferences.captureAllApps)
                if !state.preferences.captureAllApps {
                    ForEach(callApps, id: \.id) { app in
                        Toggle(app.name, isOn: Binding(get: { state.preferences.captureApps.contains(app.id) }, set: { enabled in
                            if enabled { state.preferences.captureApps.append(app.id) }
                            else { state.preferences.captureApps.removeAll { $0 == app.id } }
                        }))
                    }
                }
                Text("A browser includes audio from all of its tabs. Keep music in a different app while recording.").foregroundStyle(DesignTokens.soft)
            }
            settingsNotice
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    private let callApps = [
        (id: "us.zoom.xos", name: "Zoom"), (id: "com.microsoft.teams2", name: "Microsoft Teams"),
        (id: "com.google.Chrome", name: "Google Chrome"), (id: "com.apple.Safari", name: "Safari"),
        (id: "com.apple.FaceTime", name: "FaceTime"), (id: "com.tinyspeck.slackmacgap", name: "Slack"),
        (id: "org.mozilla.firefox", name: "Firefox"), (id: "com.microsoft.edgemac", name: "Microsoft Edge")
    ]
    private var models: some View {
        Form {
            Section("Transcription") {
                Picker("Provider", selection: $state.preferences.providers.transcription) {
                    ForEach(TranscriptionService.allCases) { Text($0.name).tag($0) }
                }
                if state.preferences.providers.transcription == .apple {
                    Text("Free, on-device. Unsupported languages are refused before recording.").foregroundStyle(DesignTokens.soft)
                    Button("Test Apple Speech") {
                        Task {
                            do { _ = try await StreamTranscriber.prepare(locale: Locale(identifier: state.preferences.locale)); state.notice = "Apple Speech is ready for this language." }
                            catch { state.notice = error.localizedDescription }
                        }
                    }
                } else {
                    ProviderKeyRow(account: state.preferences.providers.transcription.rawValue, name: state.preferences.providers.transcription.name) {
                        _ = try await CloudTranscriptionProvider(service: state.preferences.providers.transcription).transcribe(
                            wav: WaveAudio.encode(samples: Data(repeating: 0, count: 32_000)), locale: state.preferences.locale)
                    }.id("speech-" + state.preferences.providers.transcription.rawValue)
                    Text("Transcribed after Stop. A test sends one second of silence and may be billed.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                }
                LanguagePicker(locale: $state.preferences.locale, locales: state.locales)
            }
            Section("Notes") {
                Picker("Provider", selection: $state.preferences.providers.notes) {
                    ForEach(NotesService.allCases) { Text($0.name).tag($0) }
                }.onChange(of: state.preferences.providers.notes) { state.preferences.providers.model = "" }
                if state.preferences.providers.notes == .apple {
                    Text(AppleNotesProvider.unavailableReason ?? "Ready. Notes are written entirely on this Mac.").foregroundStyle(DesignTokens.soft)
                    Button("Test on-device notes") {
                        Task { do { try await AppleNotesProvider().preflight(); state.notice = "Apple's on-device notes model is ready." } catch { state.notice = error.localizedDescription } }
                    }
                } else {
                    TextField("Model", text: $state.preferences.providers.model, prompt: Text(state.preferences.providers.notes.defaultModel))
                    if state.preferences.providers.notes == .compatible {
                        TextField("HTTPS base URL", text: $state.preferences.providers.compatibleURL)
                        Text("Use an HTTPS endpoint for Ollama or LM Studio. Keys are optional for your own server.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    }
                    ProviderKeyRow(account: state.preferences.providers.notes.rawValue, name: state.preferences.providers.notes.name,
                                   optional: state.preferences.providers.notes == .compatible) {
                        let provider = CloudNotesProvider(configuration: state.preferences.providers)
                        _ = try await provider.generate(system: "Return meeting notes using the supplied schema. No action items unless stated.", user: "Test meeting: We agreed to meet on Friday. This is a connection test.")
                    }.id("notes-" + state.preferences.providers.notes.rawValue)
                    Text("A test sends a short example and may be billed.").font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                }
            }
            Section("Where your data goes") { Text(state.preferences.providers.dataFlow).foregroundStyle(DesignTokens.soft) }
            settingsNotice
        }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(state.busy || state.capture.isRecording)
    }
    private var privacy: some View {
        Form {
            Section("On this Mac") {
                LabeledContent("Meeting storage", value: ByteCountFormatter.string(fromByteCount: state.storageSize, countStyle: .file))
                Toggle("Encrypt saved meetings", isOn: Binding(get: { state.preferences.encrypted }, set: { state.setEncryption($0) }))
                    .disabled(state.busy || state.capture.isRecording)
                Text("AES-GCM encryption with a key in this Mac's Keychain. Audio is protected after recording; temporary capture files use private file permissions.").foregroundStyle(DesignTokens.soft)
                Button("Reveal in Finder") { NSWorkspace.shared.open(state.storageURL) }
                Button("Delete all meetings…", role: .destructive, action: state.deleteAll).disabled(state.busy || state.capture.isRecording)
            }
            Section("A quiet promise") {
                privacyLine("No account, server, analytics, or crash reporting.")
                privacyLine("Default speech and notes models run on this Mac.")
                privacyLine("Apple may download its models once before first use.")
                privacyLine("Automatic updates contact GitHub. Disable them in General settings.")
                privacyLine("Cloud providers run only when you choose them. No silent fallback.")
                privacyLine("API keys live in the Keychain, never in meeting files.")
                privacyLine("Search stays in memory and is rebuilt from your files.")
                privacyLine("Calendar access is read-only in Hush. No separate Google or Microsoft sign-in.")
            }
            settingsNotice
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    private func privacyLine(_ text: String) -> some View { Text(text).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true) }
    @ViewBuilder private var settingsNotice: some View {
        if let notice = state.notice { Section { Text(notice).foregroundStyle(DesignTokens.soft).textSelection(.enabled) } }
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
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            SecureField(hasKey ? "Key saved in Keychain" : optional ? "API key (optional)" : "Your API key", text: $key)
                .textFieldStyle(.roundedBorder).accessibilityLabel(name + " API key")
            HStack {
                Button("Save key") { save() }.disabled(key.isEmpty || testing)
                Button(testing ? "Testing…" : "Test") {
                    if !key.isEmpty && !save() { return }
                    testing = true; message = nil
                    Task {
                        do { try await test(); message = "Connection works." }
                        catch { message = error.localizedDescription }
                        testing = false
                    }
                }.disabled(testing || (!hasKey && key.isEmpty && !optional))
                if hasKey { Button("Remove key") { do { try Secrets.remove(account); hasKey = false; message = "Key removed." } catch { message = error.localizedDescription } }.disabled(testing) }
            }
            if let message { Text(message).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
        }.onAppear { do { hasKey = try Secrets.get(account) != nil } catch { message = error.localizedDescription } }
    }
    @discardableResult private func save() -> Bool {
        do { try Secrets.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: account); key = ""; hasKey = true; message = "Saved in Keychain."; return true }
        catch { message = error.localizedDescription; return false }
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
        Picker("Language", selection: Binding(get: { locale.replacingOccurrences(of: "_", with: "-") }, set: { locale = $0 })) {
            ForEach(choices, id: \.identifier) { language in
                Text(Locale.current.localizedString(forIdentifier: language.identifier) ?? language.identifier).tag(language.identifier)
            }
        }.font(DesignTokens.chrome)
    }
}

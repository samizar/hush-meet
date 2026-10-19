import AppKit
import SwiftUI
import Observation
import ServiceManagement
import Speech
import UserNotifications
import HushKit
import MuesliCore
import MuesliAudio
import MuesliTranscribe

/// Where the notebook window is pointed.
enum Route: Hashable {
    case home
    case tasks
    case meeting(UUID)
}

/// A short, non-blocking message at the top of the notebook or popover.
struct Banner: Identifiable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String?
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var sticky: Bool { kind == .error || kind == .warning }
}

/// What the processing queue is doing for one meeting.
struct ProcessingProgress: Equatable {
    enum Phase: Equatable {
        case waiting
        case transcribing(Double?)
        case writing(part: Int, of: Int)
    }
    var phase: Phase
    var title: String {
        switch phase {
        case .waiting: "Waiting to start…"
        case .transcribing: "Finishing the transcript…"
        case .writing(let part, let total):
            total <= 1 ? "Writing notes…" : part <= total ? "Reading part \(part) of \(total)…" : "Bringing it together…"
        }
    }
    var fraction: Double? {
        switch phase {
        case .waiting: nil
        case .transcribing(let value): value.map { $0 * 0.5 }
        case .writing(let part, let total): total <= 1 ? nil : 0.5 + 0.5 * min(0.95, Double(part) / Double(total + 1))
        }
    }
}

@MainActor @Observable
final class AppState {
    var preferences = Preferences.load() { didSet { if !isDemo, preferences != oldValue { preferences.save() } } }
    var meetings: [Meeting] = []
    var route: Route = .home
    var search = ""
    var searchHits: [SearchHit]?
    var templates: [NoteTemplate] = []
    var markdown = ""
    var displayedTranscript: Transcript?
    var banners: [Banner] = []
    var tasks: [NoteTask] = []
    var updater: AppUpdater?
    var currentID: UUID?
    var elapsed: TimeInterval = 0
    var liveNotes = ""
    var activeEvent: CalendarMeeting?
    var storageSize: Int64 = 0
    var storageURL = MeetingStore.defaultRoot
    var locales: [Locale] = []
    var damagedFolders: [URL] = []
    var autoOverrides: [String: Bool] = [:] {
        didSet { if !isDemo { UserDefaults.standard.set(autoOverrides, forKey: "hush.autoOverrides") } }
    }
    // Processing queue. Recording never waits for it.
    var queue: [UUID] = []
    var activeJob: UUID?
    var progress: [UUID: ProcessingProgress] = [:]
    /// Storage moves, encryption and delete-all pause everything else.
    var maintenance = false
    var isStarting = false
    var isStopping = false
    // Notebook view state, shared with the menu commands.
    var meetingTab = MeetingTab(rawValue: UserDefaults.standard.string(forKey: "hush.meetingTab") ?? "") ?? .notes {
        didSet { if !isDemo { UserDefaults.standard.set(meetingTab.rawValue, forKey: "hush.meetingTab") } }
    }
    var editingNotes = false
    /// Whether side notes show. Only the person's own choice is remembered, not a collapse
    /// the window makes when it's too narrow.
    var inspectorShown = UserDefaults.standard.object(forKey: "hush.sideNotesVisible") as? Bool ?? true
    func toggleInspector() {
        inspectorShown.toggle()
        if !isDemo { UserDefaults.standard.set(inspectorShown, forKey: "hush.sideNotesVisible") }
    }
    // Autosave.
    var savingIDs = Set<UUID>()
    var saveErrors: [UUID: String] = [:]
    // Ask. Questions and answers live in memory for this session only.
    var conversations: [UUID: [AskExchange]] = [:]
    /// The transcript turn a cited timestamp points at.
    var transcriptFocus: Int?

    let capture = CaptureSession()
    let calendar = CalendarService()
    let isDemo: Bool
    @ObservationIgnored var store: MeetingStore?
    @ObservationIgnored var showMain: (() -> Void)?
    @ObservationIgnored var showSettings: ((SettingsTab?) -> Void)?
    @ObservationIgnored var showCard: ((CalendarMeeting?, String?) -> Void)?
    @ObservationIgnored var dismissCard: (() -> Void)?
    @ObservationIgnored var recordingChanged: ((Bool) -> Void)?
    @ObservationIgnored var timer: Timer?
    @ObservationIgnored var tickCount = 0
    @ObservationIgnored var reminded = Set<String>()
    @ObservationIgnored var skipped = Set<String>()
    @ObservationIgnored var autoStarted = Set<String>()
    @ObservationIgnored var micReleasedAt: Date?
    @ObservationIgnored var hadCall = false
    @ObservationIgnored var detectedCall = false
    @ObservationIgnored var checkpointing = false
    @ObservationIgnored var selectionTask: Task<Void, Never>?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var scopedURL: URL?
    @ObservationIgnored var processingTask: Task<Void, Never>?
    @ObservationIgnored var writers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var dirty = Set<UUID>()
    /// Notes for `--demo` meetings, kept in memory only.
    @ObservationIgnored var demoMarkdown: [UUID: String] = [:]
    /// The providers each queued meeting was confirmed with. Later settings changes don't apply to it.
    @ObservationIgnored var jobProviders: [UUID: ProviderConfiguration] = [:]
    @ObservationIgnored var recordingActivity: NSObjectProtocol?
    @ObservationIgnored var processingActivity: NSObjectProtocol?
    /// Running Ask requests, by question.
    @ObservationIgnored var askTasks: [UUID: Task<Void, Never>] = [:]
    /// The cloud configuration the person agreed to for each meeting's questions this session.
    @ObservationIgnored var askConsent: [UUID: ProviderConfiguration] = [:]
    /// Tests replace the provider; preview mode never calls it.
    @ObservationIgnored var answerers: (ProviderConfiguration) -> any AnswerGenerator = AnswerProviders.make

    // MARK: Derived state

    var selectedID: UUID? {
        get { if case .meeting(let id) = route { id } else { nil } }
        set { route = newValue.map(Route.meeting) ?? .home }
    }
    var selected: Meeting? { selectedID.flatMap { id in meetings.first { $0.id == id } } }
    var current: Meeting? { meetings.first { $0.id == currentID } }
    var filteredMeetings: [Meeting] {
        guard let searchHits else { return meetings }
        let byID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        return searchHits.compactMap { byID[$0.id] }
    }
    func snippet(for id: UUID) -> String? { searchHits?.first { $0.id == id }?.snippet }
    var isRecording: Bool { capture.isRecording }
    var canRecord: Bool { !capture.isRecording && !capture.isPreparing && !isStarting && !isStopping && !maintenance && (store != nil || isDemo) }
    /// Any queued or running note work. Recording is separate.
    var busy: Bool { activeJob != nil || !queue.isEmpty || maintenance }
    var canCancelProcessing: Bool { activeJob != nil && processingTask != nil }
    var hasActiveMeetingWork: Bool { busy || capture.isRecording || capture.isPreparing || isStarting || isStopping }
    var preventsUpdateRestart: Bool { hasActiveMeetingWork || !savingIDs.isEmpty || !saveErrors.isEmpty }
    func isQueued(_ id: UUID) -> Bool { activeJob == id || queue.contains(id) }
    var openTasks: [NoteTask] { tasks.filter { !$0.done } }
    var nextMeeting: CalendarMeeting? {
        guard preferences.calendarEnabled else { return nil }
        return calendar.meetings.first { $0.end > .now && !skipped.contains($0.id) }
    }
    // Names kept for the side-notes autosave API.
    var sideNotesSaving: Set<UUID> { savingIDs }
    var sideNotesSaveErrors: [UUID: String] { saveErrors }

    init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        isDemo = preview
        if isDemo { seedDemo() }
        else { autoOverrides = UserDefaults.standard.dictionary(forKey: "hush.autoOverrides") as? [String: Bool] ?? [:] }
    }

    // MARK: Loading

    func load() async {
        if isDemo { return }
        do {
            if let bookmark = preferences.storageBookmark {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw HushError.message("Hush can't access the selected storage folder. Choose it again in Settings → Storage.") }
                scopedURL = url; storageURL = url
                if stale { preferences.storageBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
            }
            store = try MeetingStore(root: storageURL, encrypted: preferences.encrypted)
            templates = (try? Templates.load()) ?? []
            guard let store else { return }
            meetings = try await store.list()
            damagedFolders = await store.damaged
            if !damagedFolders.isEmpty {
                DiagnosticLog.shared.record(.storeDamaged, count: damagedFolders.count)
                let folders = damagedFolders
                show(.warning, damagedFolders.count == 1 ? "One meeting couldn't be opened" : "\(damagedFolders.count) meetings couldn't be opened",
                     detail: "Its files are kept. Everything else is here.", action: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(folders)
                }
            }
            await recoverInterrupted()
            storageSize = await store.size()
            await refreshTasks()
            if preferences.calendarEnabled { calendar.refresh() }
            locales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer?.tolerance = 0.25
            if preferences.calendarEnabled { scheduleNotifications() }
        } catch { show(.error, "Hush couldn't open your notebook", detail: error.localizedDescription) }
    }

    // MARK: Navigation and search

    func select(_ id: UUID) {
        let changed = selectedID != id
        route = .meeting(id)
        if changed { markdown = ""; displayedTranscript = nil; transcriptFocus = nil }
        selectionTask?.cancel()
        guard !isDemo else { loadDemo(id); return }
        selectionTask = Task {
            guard let store else { return }
            let notes = try? await store.markdown(id)
            let transcript = try? await store.transcript(id)
            guard !Task.isCancelled, selectedID == id else { return }
            markdown = notes ?? ""; displayedTranscript = transcript
        }
    }
    func go(_ route: Route) {
        if case .meeting(let id) = route { select(id) } else { self.route = route }
    }
    func searchChanged() {
        searchTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { searchHits = nil; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            if isDemo {
                searchHits = meetings.filter { ($0.title + ($0.structuredNotes?.summary ?? "") + $0.userNotes).localizedCaseInsensitiveContains(query) }
                    .map { SearchHit(id: $0.id, snippet: $0.preview ?? "") }
            } else {
                do {
                    let result = try await store?.searchHits(query) ?? []
                    guard !Task.isCancelled else { return }; searchHits = result
                } catch { show(.error, "Search couldn't run", detail: error.localizedDescription) }
            }
        }
    }

    // MARK: Banners

    func show(_ kind: Banner.Kind, _ title: String, detail: String? = nil, action: String? = nil, perform: (@MainActor () -> Void)? = nil) {
        banners.removeAll { $0.title == title }
        let banner = Banner(kind: kind, title: title, detail: detail, actionTitle: action, action: perform)
        banners.append(banner)
        if banners.count > 3 { banners.removeFirst(banners.count - 3) }
        guard !banner.sticky else { return }
        Task { [id = banner.id] in
            try? await Task.sleep(for: .seconds(5))
            dismiss(id)
        }
    }
    func dismiss(_ id: UUID) { withAnimation(DesignTokens.fade) { banners.removeAll { $0.id == id } } }

    // MARK: Autosave

    func update(_ id: UUID, _ body: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }; body(&meetings[index])
    }
    /// Saves the latest in-memory copy of a meeting. Rapid changes coalesce into one write,
    /// and writes for one meeting never overlap.
    func persist(_ id: UUID) {
        guard !isDemo, store != nil else { return }
        dirty.insert(id); savingIDs.insert(id)
        guard writers[id] == nil else { return }
        writers[id] = Task {
            while dirty.contains(id) {
                dirty.remove(id)
                guard let store, let meeting = meetings.first(where: { $0.id == id }) else { break }
                do { try await store.save(meeting); saveErrors[id] = nil }
                catch { saveErrors[id] = "Changes couldn't be saved. Check available disk space, then try again." }
            }
            writers[id] = nil; savingIDs.remove(id)
        }
    }
    @discardableResult func flushWrites() async -> Bool {
        while !writers.isEmpty { for task in Array(writers.values) { await task.value } }
        return saveErrors.isEmpty
    }
    @discardableResult func flushSideNotes() async -> Bool { await flushWrites() }

    // MARK: Editing

    func setSideNotes(_ id: UUID, text: String? = nil, includeInContext: Bool? = nil) {
        guard let old = meetings.first(where: { $0.id == id }) else { return }
        update(id) {
            if $0.notesContextDigest == nil, $0.structuredNotes != nil { $0.notesContextDigest = $0.contextDigest }
            if let text { $0.userNotes = text }
            if let includeInContext { $0.useSideNotesAsContext = includeInContext }
        }
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        if currentID == id { liveNotes = meeting.userNotes }
        if old.userNotes == meeting.userNotes && old.includesSideNotes == meeting.includesSideNotes && saveErrors[id] == nil { return }
        persist(id)
    }
    func rename(_ id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update(id) { $0.title = String(clean.prefix(200)) }
        persist(id)
    }
    func renameSpeaker(_ id: UUID, speaker: Speaker, to name: String) {
        update(id) {
            var names = $0.speakerNames ?? [:]
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            names[speaker.rawValue] = clean.isEmpty || clean == speaker.label ? nil : String(clean.prefix(60))
            $0.speakerNames = names.isEmpty ? nil : names
        }
        persist(id)
    }
    /// Saves notes the person edited by hand. Regenerating will ask before replacing them.
    func saveEditedNotes(_ id: UUID, markdown text: String) {
        guard text != markdown || selectedID != id else { return }
        update(id) { $0.notesEdited = true }
        if selectedID == id { markdown = text }
        if isDemo { demoMarkdown[id] = text; tasks = demoTasks(); return }
        guard let store, let meeting = meetings.first(where: { $0.id == id }) else { return }
        Task {
            do { try await store.save(meeting, markdown: text); await refreshTasks() }
            catch { show(.error, "Your edits couldn't be saved", detail: error.localizedDescription) }
        }
    }
    func toggleTask(_ task: NoteTask) {
        Task {
            let source: String
            if selectedID == task.meetingID { source = markdown }
            else if isDemo { source = demoMarkdown[task.meetingID] ?? "" }
            else { guard let text = try? await store?.markdown(task.meetingID) else { return }; source = text }
            guard let toggled = NotesMarkdown.toggling(source, line: task.line, expecting: task.text) else {
                show(.info, "These notes changed. Try again."); await refreshTasks(); return
            }
            if selectedID == task.meetingID { markdown = toggled }
            if isDemo { demoMarkdown[task.meetingID] = toggled; tasks = demoTasks(); return }
            guard let store, let meeting = meetings.first(where: { $0.id == task.meetingID }) else { return }
            do { try await store.save(meeting, markdown: toggled) }
            catch { show(.error, "Couldn't update that item", detail: error.localizedDescription) }
            await refreshTasks()
        }
    }
    func refreshTasks() async {
        if isDemo { tasks = demoTasks(); return }
        guard let store else { tasks = []; return }
        let order = Dictionary(uniqueKeysWithValues: meetings.enumerated().map { ($1.id, $0) })
        tasks = await store.tasks().filter { order[$0.meetingID] != nil }
            .sorted { (order[$0.meetingID] ?? 0, $0.line) < (order[$1.meetingID] ?? 0, $1.line) }
    }

    // MARK: Small helpers

    func copy(_ string: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string) }
    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }
    func template(for meeting: Meeting) -> NoteTemplate? { templates.first { $0.id == meeting.templateID } }
    func reloadTemplates() { if !isDemo { templates = (try? Templates.load()) ?? templates } }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { show(.error, "Couldn't change launch at login", detail: "Check System Settings → General → Login Items.") }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, models, templates, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .models: "AI Models"
        case .templates: "Templates"
        case .privacy: "Privacy"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "waveform"
        case .models: "cpu"
        case .templates: "doc.text"
        case .privacy: "lock"
        }
    }
}

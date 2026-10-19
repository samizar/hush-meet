import AppKit
import SwiftUI
import HushKit

extension AppState {
    func canDelete(_ id: UUID) -> Bool { currentID != id && !isQueued(id) && !maintenance }

    func delete(_ ids: [UUID]) {
        let targets = ids.filter(canDelete)
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Delete “\(meeting(targets[0])?.title ?? "this meeting")”?" : "Delete \(targets.count) meetings?"
        alert.informativeText = "Notes, transcripts and any saved audio are removed from this Mac. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        if !isDemo { NSApp.activate(ignoringOtherApps: true) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            // Stop autosaves first so a late write can't recreate a deleted folder.
            for id in targets { dirty.remove(id); await writers[id]?.value }
            do {
                for id in targets { if !isDemo { try await store?.delete(id) }; saveErrors[id] = nil; clearRecoveryCount(id) }
            } catch { show(.error, "Some meetings couldn't be deleted", detail: error.localizedDescription) }
            let removed = Set(targets)
            let index = meetings.firstIndex { removed.contains($0.id) } ?? 0
            meetings.removeAll { removed.contains($0.id) }
            if let selectedID, removed.contains(selectedID) {
                markdown = ""; displayedTranscript = nil
                let next = meetings.indices.contains(index) ? meetings[index] : meetings.last
                if let next { select(next.id) } else { route = .home }
            }
            await refreshTasks()
            if let store { storageSize = await store.size() }
            show(.success, targets.count == 1 ? "Meeting deleted" : "\(targets.count) meetings deleted")
        }
    }
    func delete(_ id: UUID) { delete([id]) }

    func deleteAll() {
        guard !busy, !capture.isRecording else { show(.info, "Finish recording and processing first."); return }
        let alert = NSAlert(); alert.messageText = "Delete all meetings?"
        alert.informativeText = "Every meeting, transcript, note and audio recording in Hush is permanently removed from this Mac."
        alert.alertStyle = .critical; alert.addButton(withTitle: "Delete all meetings"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        maintenance = true
        Task {
            defer { maintenance = false; pump() }
            dirty.removeAll(); await flushWrites()
            do {
                if !isDemo { try await store?.deleteAll() }
                meetings = []; route = .home; markdown = ""; displayedTranscript = nil; storageSize = 0
                saveErrors = [:]; tasks = []; damagedFolders = []
                show(.success, "All meetings deleted")
            } catch { show(.error, "Couldn't delete every meeting", detail: error.localizedDescription) }
        }
    }

    func setEncryption(_ enabled: Bool) {
        guard !busy, !capture.isRecording else { show(.info, "Finish recording and processing first."); return }
        maintenance = true
        Task {
            defer { maintenance = false; pump() }
            do {
                guard await flushWrites() else { throw HushError.message("Save your side notes before changing encryption.") }
                try await store?.setEncryption(enabled); preferences.encrypted = enabled
                show(.success, enabled ? "Meetings are now encrypted" : "Encryption turned off")
            }
            catch { show(.error, "Encryption couldn't be changed", detail: error.localizedDescription) }
        }
    }

    func chooseStorage() {
        guard !busy, !capture.isRecording else { show(.info, "Finish recording and processing first."); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Move meetings here"
        panel.message = "Choose an empty folder. Hush moves your meetings into it and keeps using it."
        guard panel.runModal() == .OK, let url = panel.url, url.standardizedFileURL != storageURL.standardizedFileURL else { return }
        let access = url.startAccessingSecurityScopedResource()
        maintenance = true
        Task {
            defer { maintenance = false; pump() }
            do {
                guard await flushWrites() else { throw HushError.message("Save your side notes before moving storage.") }
                guard !url.resolvingSymlinksInPath().path.hasPrefix(storageURL.resolvingSymlinksInPath().path + "/") else {
                    throw HushError.message("Choose a folder outside the current meeting store.")
                }
                let existing = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
                guard existing.isEmpty else { throw HushError.message("Choose an empty folder for your meetings.") }
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let originals = try FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
                var copied: [URL] = []
                var committed = false
                do {
                    for original in originals {
                        let target = url.appendingPathComponent(original.lastPathComponent)
                        try FileManager.default.copyItem(at: original, to: target); copied.append(target)
                    }
                    let newStore = try MeetingStore(root: url, encrypted: preferences.encrypted)
                    let moved = try await newStore.list()
                    guard moved.count >= meetings.count else { throw HushError.message("Not every meeting copied correctly. Nothing was moved.") }
                    store = newStore; preferences.storageBookmark = bookmark
                    scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = access ? url : nil
                    storageURL = url
                    committed = true
                    var leftovers = false
                    for original in originals {
                        do { try FileManager.default.removeItem(at: original) } catch { leftovers = true }
                    }
                    show(.success, "Meetings moved", detail: leftovers ? "A copy remains in the previous folder and can be removed in Finder." : url.path(percentEncoded: false))
                } catch {
                    if !committed { for copiedURL in copied { try? FileManager.default.removeItem(at: copiedURL) } }
                    throw error
                }
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                show(.error, "Meetings weren't moved", detail: error.localizedDescription)
            }
        }
    }

    func addToReminders(_ items: [NoteTask]) {
        guard !items.isEmpty, !isDemo else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let requests = items.map { task -> (title: String, notes: String, due: DateComponents?) in
            let parts = NoteParser.taskParts(task.text)
            let source = meeting(task.meetingID).map { "From “\($0.title)” on \($0.startedAt.formatted(date: .abbreviated, time: .omitted))." } ?? ""
            let owner = parts.owner.map { $0 == "Me" ? "" : " Owner: \($0)." } ?? ""
            let due = parts.due.flatMap { formatter.date(from: $0) }.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
            return (parts.title, source + owner, due)
        }
        Task {
            do {
                let count = try await calendar.addReminders(requests)
                show(.success, count == 1 ? "Added to Reminders" : "\(count) items added to Reminders")
            } catch { show(.error, "Couldn't add to Reminders", detail: error.localizedDescription) }
        }
    }

    func revealFolder(_ id: UUID) {
        Task { if let folder = await store?.folder(id) { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
    }
}

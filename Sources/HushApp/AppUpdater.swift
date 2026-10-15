import AppKit
import Observation
@preconcurrency import Sparkle

/// Sparkle owns update transport and verified installation. Meeting/provider networking stays separate.
@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    private(set) var canCheck = false
    private(set) var automaticChecks = true
    private(set) var automaticInstallation = true
    private(set) var lastChecked: Date?
    private(set) var status: String?
    private(set) var updateAvailable = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var postponedRelaunch: Task<Void, Never>?
    @ObservationIgnored private let isBusy: () -> Bool
    @ObservationIgnored private let isDemo: Bool

    init(isDemo: Bool, isBusy: @escaping () -> Bool) {
        self.isDemo = isDemo; self.isBusy = isBusy
        super.init()
        guard !isDemo else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        guard let updater = controller?.updater else { return }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
        refresh()
    }

    func start() {
        guard !isDemo, let updater = controller?.updater else { return }
        do { try updater.start() }
        catch { status = "Updates couldn't start: \(error.localizedDescription)" }
        refresh()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    func checkForUpdates() {
        guard canCheck, !isBusy() else { return }
        controller?.checkForUpdates(nil)
    }

    private func refresh() {
        guard let updater = controller?.updater else { return }
        canCheck = updater.canCheckForUpdates
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticInstallation = updater.automaticallyDownloadsUpdates
        lastChecked = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !isBusy() else {
            throw NSError(domain: "app.hush.updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hush will check for updates after the recording and notes finish."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        status = "Update ready. Waiting for your meeting to finish."
        postponedRelaunch?.cancel()
        postponedRelaunch = Task { [weak self] in
            while let self, self.isBusy() {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            guard self != nil, !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        status = "Update ready. It will install when Hush quits."
        return false
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Sparkle still installs automatic updates on quit; an active meeting never gets an update alert.
        !isBusy()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updateAvailable = true
        status = "Hush \(update.displayVersionString) is available."
    }

    func standardUserDriverWillFinishUpdateSession() { updateAvailable = false }
}

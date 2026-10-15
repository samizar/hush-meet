import Foundation
import Testing
import Sparkle
@testable import HushApp

@Suite("Automatic update safety") @MainActor
struct UpdaterTests {
    private func sparkle() -> SPUUpdater {
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater
    }

    private func item() throws -> SUAppcastItem {
        SUAppcastItem.empty()
    }

    @Test func previewNeverStartsUpdateChecks() {
        let service = AppUpdater(isDemo: true, isBusy: { false })
        service.start(); service.checkForUpdates()
        #expect(!service.canCheck)
        #expect(service.lastChecked == nil)
    }

    @Test func activeWorkBlocksBothManualAndBackgroundChecks() {
        let service = AppUpdater(isDemo: true, isBusy: { true })
        let updater = sparkle()
        #expect(throws: NSError.self) { try service.updater(updater, mayPerform: .updatesInBackground) }
        #expect(throws: NSError.self) { try service.updater(updater, mayPerform: .updates) }
    }

    @Test func idleWorkAllowsChecks() throws {
        let service = AppUpdater(isDemo: true, isBusy: { false })
        try service.updater(sparkle(), mayPerform: .updatesInBackground)
    }

    @Test func restartWaitsUntilWorkFinishes() async throws {
        var busy = true
        var installed = false
        let service = AppUpdater(isDemo: true, isBusy: { busy })
        #expect(service.updater(sparkle(), shouldPostponeRelaunchForUpdate: try item(), untilInvokingBlock: { installed = true }))
        try await Task.sleep(for: .milliseconds(40))
        #expect(!installed)
        busy = false
        for _ in 0..<30 where !installed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(installed)
    }

    @Test func scheduledAlertsWaitDuringMeetings() throws {
        var busy = true
        let service = AppUpdater(isDemo: true, isBusy: { busy })
        let update = try item()
        #expect(!service.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: true))
        busy = false
        #expect(service.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: false))
    }
}

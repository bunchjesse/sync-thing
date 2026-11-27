import AppKit
import Sparkle

/// Keeps SyncThing up to date with Sparkle, from the appcast at the
/// `SUFeedURL` in Info.plist. Since SyncThing has no Dock icon, a scheduled
/// check only opens Sparkle's window when the app was just launched or the
/// Mac is idle; otherwise the update waits in the menu as
/// ``availableVersion``.
@MainActor
@Observable
final class Updater: NSObject {
    /// Whether this build updates itself: false in Debug builds, which are a
    /// separate app.
    static var isEnabled: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// Whether the user can check for updates now: false while a check or
    /// an update is under way, and in Debug builds.
    private(set) var canCheckForUpdates = false

    /// The version a scheduled check found, until the user sees it or the
    /// update session ends.
    private(set) var availableVersion: String?

    /// Whether Sparkle checks for updates on its own, once a day by default.
    var automaticallyChecksForUpdates = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Sparkle's updater and its standard windows; nil in Debug builds.
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// Mirrors Sparkle's state into the observable properties above.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Starts Sparkle, except in Debug builds.
    override init() {
        super.init()
        guard Self.isEnabled else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let canCheck = change.newValue ?? false
                Task { @MainActor in self?.canCheckForUpdates = canCheck }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                let automatically = change.newValue ?? false
                Task { @MainActor in self?.automaticallyChecksForUpdates = automatically }
            },
        ]
    }

    /// Brings the app forward and checks for an update, showing one a
    /// scheduled check already found.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    /// Lets the menu show updates that Sparkle doesn't put on screen.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Shows a scheduled update at once only when the app was just launched
    /// or the Mac is idle.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    /// Offers an update in the menu when Sparkle isn't showing it.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            availableVersion = update.displayVersionString
        }
    }

    /// Drops the menu's offer once the user has seen the update.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    /// Drops the menu's offer when the update is installed, skipped, or
    /// dismissed.
    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}

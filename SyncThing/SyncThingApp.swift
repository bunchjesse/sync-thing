import AppKit
import Foundation
import SwiftUI
import SyncKit

/// A menu bar app that keeps chosen folders and files the same on every Mac
/// signed in to this Apple Account.
@main
struct SyncThingApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Window("SyncThing", id: SyncWindow.id) {
            SyncWindow(controller: appDelegate.controller)
        }
        .defaultSize(width: 520, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
    }
}

/// Owns the controller and starts syncing at launch, whether or not the
/// menu or the window is ever opened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The controller every scene shows.
    let controller = SyncController(configuration: .current)

    /// Starts syncing.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await controller.start() }
    }
}

/// The menu bar icon, which spins while files are syncing and shows an
/// exclamation mark while items wait for the user's choice.
struct MenuBarIcon: View {
    /// The controller whose state the icon shows.
    let controller: SyncController

    var body: some View {
        let needsChoice = controller.joinQuestion != nil
        Image(systemName: needsChoice ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
            .symbolEffect(.rotate, isActive: controller.isSyncing)
            .accessibilityLabel(needsChoice ? "SyncThing, needs your choice" : controller.isSyncing ? "SyncThing, syncing" : "SyncThing")
    }
}

extension SyncConfiguration {
    /// The configuration for this build.
    ///
    /// Debug and Release builds use separate Keychain items, Bonjour types,
    /// protocol names, and relay namespaces, so a development build never
    /// syncs with the copy in daily use. Debug builds also honor
    /// `SYNCTHING_INSTANCE` and `SYNCTHING_HOME`, so two copies can run side
    /// by side on one Mac, each with its own identity and home folder.
    static var current: SyncConfiguration {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let suffix = ".debug"
        let protocolName = "syncthing-debug/1"
        let serviceType = "_sync-thing-dbg._tcp"
        let instance = environment["SYNCTHING_INSTANCE"].flatMap { $0.isEmpty ? nil : $0 }
        let home = environment["SYNCTHING_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        #else
        let suffix = ""
        let protocolName = "syncthing/1"
        let serviceType = "_sync-thing._tcp"
        let instance: String? = nil
        let home: URL? = nil
        #endif

        let stateDirectory = URL.applicationSupportDirectory
            .appending(path: "SyncThing\(suffix)", directoryHint: .isDirectory)
            .appending(path: instance ?? "default", directoryHint: .isDirectory)
        let hostName = Host.current().localizedName ?? "Mac"
        return SyncConfiguration(
            remoteAccess: RemoteAccessConfiguration(
                keychainServicePrefix: "dev.bunch.SyncThing\(suffix)",
                keychainAccessGroup: nil,
                protocolName: protocolName,
                serviceType: serviceType,
                localInstance: instance
            ),
            deviceName: instance.map { "\(hostName) (\($0))" } ?? hostName,
            stateDirectory: stateDirectory,
            locations: home.map { SyncLocations(home: $0) } ?? SyncLocations()
        )
    }
}

import Foundation
import SwiftUI
import SyncKit

/// A menu bar app that keeps chosen folders and files the same on every Mac
/// signed in to this Apple Account.
@main
struct SyncThingApp: App {
    @State private var controller = SyncController(configuration: .current)

    var body: some Scene {
        MenuBarExtra {
            SyncMenu(controller: controller)
        } label: {
            MenuBarIcon(isSyncing: controller.isSyncing)
                .task { await controller.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon, which spins while files are syncing.
struct MenuBarIcon: View {
    /// Whether a pull is under way.
    let isSyncing: Bool

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .symbolEffect(.rotate, isActive: isSyncing)
            .accessibilityLabel(isSyncing ? "SyncThing, syncing" : "SyncThing")
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

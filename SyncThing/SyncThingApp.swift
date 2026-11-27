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
            StatusMenu(controller: appDelegate.controller, updater: appDelegate.updater)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Window("SyncThing", id: SyncWindow.id) {
            SyncWindow(controller: appDelegate.controller, updater: appDelegate.updater)
        }
        .defaultSize(width: 520, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
    }
}

/// Owns the controller and the updater, and starts syncing at launch,
/// whether or not the menu or the window is ever opened.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The controller every scene shows.
    let controller = SyncController(configuration: .current)
    /// Keeps the app up to date.
    let updater = Updater()

    /// Starts syncing.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await controller.start() }
    }
}

/// The menu bar icon, which shows an exclamation mark while items wait for
/// the user's choice and spins while files are syncing. Debug builds show a
/// ladybug beside the arrows, so they're never mistaken for the copy in
/// daily use, and fill the arrows instead of spinning them.
struct MenuBarIcon: View {
    /// The controller whose state the icon shows.
    let controller: SyncController

    #if DEBUG
    /// The app's name as VoiceOver reads it.
    private static let appName = "SyncThing Debug"
    #else
    /// The app's name as VoiceOver reads it.
    private static let appName = "SyncThing"
    #endif

    var body: some View {
        let needsChoice = controller.joinQuestion != nil
        icon(needsChoice: needsChoice)
            .accessibilityLabel(needsChoice ? "\(Self.appName), needs your choice" : controller.isSyncing ? "\(Self.appName), syncing" : Self.appName)
    }

    /// The arrows, with the exclamation mark when `needsChoice`.
    @ViewBuilder private func icon(needsChoice: Bool) -> some View {
        #if DEBUG
        let symbol = needsChoice
            ? "exclamationmark.arrow.triangle.2.circlepath"
            : controller.isSyncing ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath"
        Image(nsImage: Self.debugImage(symbol))
        #else
        Image(systemName: needsChoice ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
            .symbolEffect(.rotate, isActive: controller.isSyncing)
        #endif
    }

    #if DEBUG
    /// The images ``debugImage(_:)`` drew, by symbol.
    private static var debugImages: [String: NSImage] = [:]

    /// `symbol` and a ladybug side by side in one template image. A menu
    /// bar label shows only its first image, so the two can't be separate
    /// views, and a drawn image can't spin.
    private static func debugImage(_ symbol: String) -> NSImage {
        if let image = debugImages[symbol] {
            return image
        }
        let configuration = NSImage.SymbolConfiguration(textStyle: .body, scale: .large)
        let parts = [symbol, "ladybug.fill"].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        assert(parts.count == 2, "Missing symbol \(symbol) or ladybug.fill")
        let spacing: CGFloat = 3
        let size = NSSize(
            width: parts.map(\.size.width).reduce(0, +) + spacing * CGFloat(parts.count - 1),
            height: parts.map(\.size.height).max() ?? 0
        )
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(in: NSRect(x: x, y: (size.height - part.size.height) / 2, width: part.size.width, height: part.size.height))
                x += part.size.width + spacing
            }
            return true
        }
        image.isTemplate = true
        debugImages[symbol] = image
        return image
    }
    #endif
}

#Preview("Menu Bar Icon") {
    HStack(spacing: 24) {
        MenuBarIcon(controller: .preview())
        MenuBarIcon(controller: .preview(peers: [SyncController.PeerState(id: "a", name: "Studio", connection: .connected(.direct), isSyncing: true)]))
        MenuBarIcon(controller: .preview(joinQuestion: JoinQuestion(items: [JoinQuestion.Item(id: "~/Notes", differingFiles: 3)])))
    }
    .padding()
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

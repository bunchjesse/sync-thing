import AppKit
import SwiftUI
import SyncKit

/// The menu the menu bar icon opens: the synced files that changed most
/// recently, the way into SyncThing's window, and updates.
struct StatusMenu: View {
    /// The controller whose state the menu shows.
    let controller: SyncController
    /// The updater whose updates the menu offers.
    let updater: Updater

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let version = updater.availableVersion {
            Button("Update to SyncThing \(version)…", systemImage: "arrow.down.circle", action: updater.checkForUpdates)
                .labelStyle(.titleAndIcon)
            Divider()
        }
        if case .unavailable(let reason) = controller.status {
            Label("SyncThing can’t sync: \(reason)", systemImage: "exclamationmark.triangle")
                .labelStyle(.titleAndIcon)
        } else {
            Text(summary)
        }
        if controller.joinQuestion != nil {
            Button("Choose Which Copies to Keep…", systemImage: "exclamationmark.arrow.triangle.2.circlepath", action: openSyncThing)
                .labelStyle(.titleAndIcon)
        }
        Divider()
        Section("Recently Changed") {
            if controller.recentFiles.isEmpty {
                Text("No synced files yet")
            } else {
                ForEach(controller.recentFiles) { file in
                    RecentFileItem(file: file)
                }
            }
        }
        .labelStyle(.titleAndIcon)
        Divider()
        Button("Open SyncThing", action: openSyncThing)
            .keyboardShortcut("o")
        if Updater.isEnabled {
            Button("Check for Updates…", action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        }
        Divider()
        Button("Quit SyncThing") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// How syncing stands: starting, pulling, no other Macs yet, or which
    /// of the other Macs this one reaches.
    private var summary: String {
        if controller.status == .starting {
            return "Starting…"
        }
        if controller.isSyncing {
            return "Syncing…"
        }
        let peers = controller.peers
        let connected = peers.filter(\.isConnected)
        if peers.isEmpty {
            return "No other Macs yet"
        }
        if connected.isEmpty {
            return "Not connected to your other Macs"
        }
        if connected.count == peers.count {
            return connected.count == 1 ? "Connected to \(connected[0].name)" : "Connected to \(connected.count) Macs"
        }
        return "Connected to \(connected.count) of \(peers.count) Macs"
    }

    /// Opens SyncThing's window and brings the app forward.
    private func openSyncThing() {
        openWindow(id: SyncWindow.id)
        NSApp.activate()
    }
}

/// One recently changed file, which opens when chosen, or is shown in the
/// Finder when chosen with Option held.
private struct RecentFileItem: View {
    /// The file the item opens.
    let file: RecentFile

    var body: some View {
        Button {
            NSWorkspace.shared.open(file.url)
        } label: {
            Label { Text(file.url.lastPathComponent) } icon: { Image(nsImage: icon) }
            Text(detail)
        }
        .modifierKeyAlternate(.option) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Label("Show \(file.url.lastPathComponent) in Finder", systemImage: "folder")
                Text(detail)
            }
        }
    }

    /// The file's Finder icon, at menu size.
    private var icon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: file.url.path(percentEncoded: false))
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// The folder the file is in, and when it changed: the time for today,
    /// otherwise the date, so it stays right while the menu is open.
    private var detail: String {
        let folder = (file.url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        let calendar = Calendar.current
        let changed = if calendar.isDateInToday(file.changed) {
            file.changed.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDate(file.changed, equalTo: .now, toGranularity: .year) {
            file.changed.formatted(.dateTime.month(.abbreviated).day())
        } else {
            file.changed.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(folder) · \(changed)"
    }
}

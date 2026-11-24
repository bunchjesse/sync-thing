# AGENTS.md

SyncThing is a macOS menu bar app that syncs chosen folders and files between
the Macs on one Apple Account. See `README.md` for the design.

## Layout

- `SyncThing/` — the app target. Keep it thin: the `MenuBarExtra`, the menu
  view, and `SyncConfiguration.current`.
- `Packages/SyncKit/` — all logic, so it can be tested with `swift test`:
  - `SyncLocations`, `SyncModel` — portable paths, timestamps, records, and the
    last-writer-wins rules (`supersedes`).
  - `FileScanner` — builds an item's index from disk.
  - `SyncEngine` — the actor that owns items and indexes, rescans, and pulls
    from a `SyncPeer`.
  - `SyncStore` — JSON state under Application Support.
  - `SyncServer` / `HTTPSyncPeer` — the loopback HTTP API and its client.
  - `FileWatcher` — FSEvents.
  - `SyncController` — wires the engine to DeviceTunnel and publishes UI state.

## Building and testing

- Build and run the app with the Xcode MCP tools (`BuildProject`,
  `RunProject`), not `xcodebuild`.
- The project uses the text `project.xcproj` format. Change build settings,
  Info.plist keys, and entitlements with the Xcode tools, not by hand.
- Test SyncKit with `swift test --package-path Packages/SyncKit`. Tests use
  Swift Testing, and every test has a `///` comment saying what it checks.
- Engine tests run several `SyncEngine`s in temporary directories against each
  other through `EnginePeer`; add new sync behavior tests there.

## Rules

- Never let a pull delete files because something is missing locally: a missing
  item root pauses the item (`FileScanner.Outcome.rootMissing`), and a path the
  scanner can't read keeps its previous records.
- Every path a peer sends goes through `SyncEngine.isSafe(path:in:)` or
  `isSafeItemID` before touching disk, every write and read goes through
  `hasNoLinks(below:to:includingTarget:)`, and every peer timestamp through
  `isPlausible`. Items from peers pass the same `admissionProblem(for:)` check
  as local adds.
- Debug and Release must stay separate sync networks; don't share Keychain
  prefixes, Bonjour types, or protocol names between them.
- The Bonjour types must stay listed in `NSBonjourServices`.

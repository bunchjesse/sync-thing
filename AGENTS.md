# AGENTS.md

SyncThing is a macOS menu bar app that syncs chosen folders and files between
the Macs on one Apple Account. See `README.md` for the design.

## Layout

- `SyncThing/` — the app target. Keep it thin: `SyncThingApp` (the
  `MenuBarExtra` and the window scene; its `AppDelegate` owns the
  `SyncController` and the `Updater`), `StatusMenu` (a status line, recent
  files, Open, Check for Updates, Quit), `SyncWindow` (items, Macs and Sync
  Now, the join question, options, and updates), `Updater` (Sparkle's
  `SPUStandardUpdaterController`
  with gentle reminders, since the app has no Dock icon), `AppIcon.icon` and
  `AppIconDebug.icon` (Icon Composer icons with SVG layers), and
  `SyncConfiguration.current`.
- `Packages/SyncKit/` — all logic, so it can be tested with `swift test`:
  - `SyncLocations`, `SyncModel` — portable paths, timestamps, records, and the
    conflict rules: `VersionVector` orders a path's versions, and
    `FileRecord.winsConflict(over:)` decides between concurrent ones.
  - `FileScanner` — builds an item's index from disk.
  - `SyncEngine` — the actor that owns items and indexes, rescans, and pulls
    from a `SyncPeer`, asking only for what changed (`IndexPosition`). It also
    lists the newest files for the menu (`recentFiles(limit:)`).
  - `SyncStore` — JSON state under Application Support.
  - `SyncServer` / `HTTPSyncPeer` — the loopback HTTP API (`/v1/…`) and its
    client.
  - `FileWatcher` — FSEvents.
  - `SyncController` — wires the engine to DeviceTunnel and publishes UI state.

## Building and testing

- Build and run the app with the Xcode MCP tools (`BuildProject`,
  `RunProject`), not `xcodebuild`. The exception is releasing: use the
  `release` skill (`.symphony/skills/release/`), whose script archives and
  notarizes with `xcodebuild`.
- Building a release and publishing it are separate. `release.sh` stays on
  this Mac; `publish.sh` pushes and creates the GitHub release that every
  installed copy updates from. Only publish when the user says "publish".
- The project uses the text `project.xcproj` format. Change build settings,
  Info.plist keys, and entitlements with the Xcode tools, not by hand. The
  exceptions are `[config=…]` settings and package references, which the
  tools can't write; after any tool change, check `git diff`, since Xcode's
  save can collapse `[config=…]` pairs and rename the product to
  `SyncThingDebug.app`.
- Test SyncKit with `swift test --package-path Packages/SyncKit`. Tests use
  Swift Testing, and every test has a `///` comment saying what it checks.
- Engine tests run several `SyncEngine`s in temporary directories against each
  other through `EnginePeer` (`TestSupport.swift`; `FaultyPeer` injects
  failures, `RecordingPeer` keeps the batches served, and each `TestMac`'s
  `trash` lists what it threw away). Suites are split by scenario:
  `NewMacTests`, `ConflictTests`, `ItemTests`, `DegenerateInputTests`,
  `FailureTests`; add new sync behavior tests to the matching one. Joining and
  the `JoinChoice` question belong in `NewMacTests`. `RandomizedTests` replays
  200 seeded random histories across three Macs and checks they converge with
  no kept copy lost; a failure prints the seed and the history.
- Use `ago(_:)` for test modification times: change times are capped at now,
  so a future time doesn't win.

## Rules

- Never let a pull delete files because something is missing locally: a missing
  item root pauses the item (`FileScanner.Outcome.rootMissing`), and a path the
  scanner can't read — or that is a symbolic link — keeps its previous
  records.
- A Mac's own changes only move its `macID` counter in a `VersionVector`. In a
  conflict only the losing Mac changes anything: it trashes its copy and takes
  the winner's record with both vectors merged. The winner never merges.
- Plan a pull against the peer's whole index as last pulled, not just the
  changes in the latest batch, so paths that didn't sync are tried again.
  Every change to an index goes through `commit(_:for:changing:)`, which
  numbers it for peers; a path leaving the index starts a new one.
- Compare and name paths by `SyncLocations.realPath`/`portablePath`, which
  resolve links, `/private`, and case, never by the spelling given.
- An item that reaches a copy this Mac already had is held for the user's
  `JoinChoice` (`SyncEngine.awaitingChoice`): never pull into it or serve it
  until `answerJoin` settles it.
- Every path a peer sends goes through `SyncEngine.isSafe(path:in:)` or
  `isSafeItemID` before touching disk, every write and read goes through
  `hasNoLinks(below:to:includingTarget:)`, and every peer record through
  `isPlausible`, which checks its timestamps and version vector. Items from
  peers pass the same `admissionProblem(for:)` check as local adds.
- Debug and Release must stay separate sync networks; don't share Keychain
  prefixes, Bonjour types, or protocol names between them.
- Debug is also a separate app: `SyncThingDebug.app`, bundle ID
  `dev.bunch.SyncThingDebug`, the `AppIconDebug` icon, and a ladybug in the
  menu bar icon. Its settings are `[config=Debug]` variants in
  `project.xcproj` (with a `[config=Release]` twin each, since an
  unconditioned value would win), and `PRODUCT_MODULE_NAME` stays
  `SyncThing` in both. The Keychain access group follows
  `$(PRODUCT_BUNDLE_IDENTIFIER)`. `AppIconDebug.icon` keeps its own copy of
  `arrows.svg`; change both icons together.
- Debug builds never start Sparkle (`Updater.isEnabled`), so they're never
  offered a Release build.
- Every published build raises `CURRENT_PROJECT_VERSION`; Sparkle orders
  builds by it. Never generate a new Sparkle key: installed copies trust
  only `SUPublicEDKey`. The private key is
  `~/Documents/SigningKeys/SyncThing/sparkle-private-key.txt`; never commit
  it or put it in the Keychain.
- The Bonjour types must stay listed in `NSBonjourServices`.
- Nothing has shipped yet: change the HTTP API and saved formats freely,
  keep the routes at `/v1`, and don't add migrations or compatibility code
  until v1 ships.

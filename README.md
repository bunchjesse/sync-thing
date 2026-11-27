# SyncThing

A menu bar app that keeps chosen folders and files the same on every Mac
signed in to your Apple Account. Pick a folder (or a single file such as
`~/.zshrc`) on any Mac and it appears, and stays current, at the same place
on all of them.

There's no server and no setup beyond iCloud Keychain. Macs find each other
on the local network with Bonjour, and can optionally meet through a
[rendezvous relay](https://github.com/bunchjesse/rendezvous-relay) when
they're on different networks.

The menu bar icon lists the ten most recently changed synced files; click one
to open it, or hold Option to show it in Finder. **Open SyncThing** opens the
window where you add and remove folders and files, see your other Macs, and
set the relay and Open at Login.

## How it works

- **Discovery and trust** come from
  [device-tunnel](https://github.com/bunchjesse/device-tunnel). Each Mac has
  an Ed25519 identity and publishes a record in an iCloud Keychain synced
  registry. Any Mac in that registry — that is, signed in to the same Apple
  Account — is trusted automatically.
- **Transport**: each Mac runs a small HTTP server on `127.0.0.1` (Hummingbird).
  Other Macs reach it only through an SSH tunnel, with a bearer token issued
  per Mac when its tunnel is admitted.
- **Syncing is pull-based.** Each Mac pulls from every connected Mac when it
  connects, when that Mac says it changed (`POST /v1/changed`), and every
  minute. A pull asks only for what changed since the last one; a Mac that
  relaunched sends its whole index once. Changes on disk are picked up with
  FSEvents, plus a full rescan at launch, on wake, and every ten minutes.
- **Conflicts** are decided by what each Mac had seen, not by clocks. Every
  file's version is a version vector: a counter per Mac that changed it. An
  edit made after seeing another Mac's replaces it, whatever the modification
  times say. Only edits made on two Macs before either saw the other's
  conflict; then the later change wins everywhere, an edit always beats a
  concurrent deletion, and ties break the same way on every Mac. Only the
  Mac whose copy lost does anything: its copy goes to its Trash, where it
  can be put back. Change times are capped at the scan's time, so a file
  stamped in the future can't win every conflict, and times and counters
  more than a week ahead of this Mac's clock are ignored. A file whose
  contents already match the winner is adopted without a download; one that
  was only touched keeps its version.
- **Deletions** are a Mac's change like any other, so one made after seeing
  an edit wins, and the edit goes to the Trash. Deleted files go to the Trash
  (or are removed outright on a volume without one); a folder is removed only
  once it's empty, and one holding files outranks a peer that replaced it
  with a file. Deletions are remembered as tombstones for about fifteen
  months; a Mac away longer than that may bring a deleted file back.
- **A Mac joining** pulls the item list from each Mac it connects to and
  creates any missing folder. An item that reaches a copy this Mac already
  had — restored, cloned, or copied, so its modification times can't be
  trusted — is held: it isn't pulled into or served, and the window asks once,
  for every such item, whether to use the other Macs' copies or this Mac's.
  The losing side's differing files go to its Trash. A copy with nothing the
  others lack syncs without asking. A folder added on two Macs separately,
  before they met, isn't held: both copies are SyncThing's, and their files
  conflict like any concurrent edits. A pull that's interrupted resumes where
  it left off. Other Macs notice a new one when it first tells them it
  changed, or within 15 minutes, when they re-read the registry.
- **Safety**: an item whose folder is missing on a Mac — an unmounted drive —
  or whose single file became a folder or a link pauses there instead of
  deleting the files everywhere, and a folder or file that can't be read keeps
  its records rather than looking deleted. A file changed on this Mac since
  its last scan is never overwritten by a pull. Pulls never write, and the
  server never reads, through a symbolic link inside an item; a file or
  folder replaced by a link keeps its records. Two names that differ only in
  case can't both live on a case-insensitive disk, so the second one is
  reported as failed rather than overwriting the first. A peer's token is
  revoked when its tunnel closes, which ends any pull in progress.
- **The list of items syncs too.** Adding or removing an item on one Mac does so
  on all of them; removing one leaves its files in place. A Mac ignores an
  item from a peer that it wouldn't accept from its own user, such as one
  overlapping an item it already syncs, or one it would name differently
  (another case, or a path through a link).

Paths in the home folder are portable (`~/Documents/Notes`), so Macs with
different user names agree. Symbolic links, permissions, and extended
attributes don't sync, nor do `.DS_Store` and the other bookkeeping files
Finder and Spotlight keep in folders.

## Layout

| Path | What |
|------|------|
| `SyncThing/` | The app: the menu bar menu (`StatusMenu`), the window (`SyncWindow`), the icon (`AppIcon.icon`), and per-build configuration |
| `Packages/SyncKit/` | Everything else: scanner, engine, store, HTTP server and client, watcher, and `SyncController` |

## Building

Open `SyncThing.xcodeproj` and run the **SyncThing** scheme. The app isn't
sandboxed, so it can sync any path; macOS asks for access to Documents,
Desktop, and similar folders the first time it touches them.

Run the SyncKit tests with:

```sh
swift test --package-path Packages/SyncKit
```

`.symphony/skills/release/scripts/release.sh` builds a notarized Developer
ID release into `~/Downloads/SyncThing-<version>/`; the `release` skill
beside it walks through the version bump and commit around it.

### Debug builds

Debug and Release builds are separate sync networks: different Keychain items,
Bonjour type (`_sync-thing-dbg._tcp` vs `_sync-thing._tcp`), protocol name, and
relay namespace (`dev.bunch.SyncThing.debug` vs `dev.bunch.SyncThing`).

Debug builds read two environment variables, so two copies can sync with each
other on one Mac:

```sh
APP=path/to/Debug/SyncThing.app
open -n --env SYNCTHING_INSTANCE=a --env SYNCTHING_HOME=/tmp/a "$APP"
open -n --env SYNCTHING_INSTANCE=b --env SYNCTHING_HOME=/tmp/b "$APP"
```

### Relay

The relay is off by default. To use one, enter its `host[:port]` in the
SyncThing window's Options.
The relay must allow the build's namespace — for the deployment in
`personal-site`, add `dev.bunch.SyncThing` and `dev.bunch.SyncThing.debug` to
`RELAY_ALLOWED_NAMESPACES`.

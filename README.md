# SyncThing

A menu bar app that keeps chosen folders and files the same on every Mac
signed in to your Apple Account. Pick a folder (or a single file such as
`~/.zshrc`) on any Mac and it appears, and stays current, at the same place
on all of them.

There's no server and no setup beyond iCloud Keychain. Macs find each other
on the local network with Bonjour, and can optionally meet through a
[rendezvous relay](https://github.com/bunchjesse/rendezvous-relay) when
they're on different networks.

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
  minute. Changes on disk are picked up with FSEvents, plus a full rescan at
  launch, on wake, and every ten minutes.
- **Conflicts**: newest wins, silently. Each file's version is its
  modification time, and a file that replaces an older record always goes
  after it. Ties break the same way on every Mac. Timestamps more than a week
  ahead of this Mac's clock are ignored.
- **Deletions**: deleted files go to the Trash (or are removed outright on a
  volume without one); a folder is removed only once it's empty. Deletions are
  remembered as tombstones for 90 days; a Mac away longer than that may bring
  a deleted file back.
- **Safety**: an item whose folder is missing on a Mac — an unmounted drive —
  pauses there instead of deleting the files everywhere, and a folder or file
  that can't be read keeps its records rather than looking deleted. A file
  changed on this Mac since its last scan is never overwritten by a pull.
  Pulls never write, and the server never reads, through a symbolic link
  inside an item.
- **The list of items syncs too.** Adding or removing an item on one Mac does so
  on all of them; removing one leaves its files in place. A Mac ignores an
  item from a peer that it wouldn't accept from its own user, such as one
  overlapping an item it already syncs.

Paths in the home folder are portable (`~/Documents/Notes`), so Macs with
different user names agree. Symbolic links, permissions, and extended
attributes don't sync, nor do `.DS_Store` and the other bookkeeping files
Finder and Spotlight keep in folders.

## Layout

| Path | What |
|------|------|
| `SyncThing/` | The app: `MenuBarExtra`, menu UI, and per-build configuration |
| `Packages/SyncKit/` | Everything else: scanner, engine, store, HTTP server and client, watcher, and `SyncController` |

## Building

Open `SyncThing.xcodeproj` and run the **SyncThing** scheme. The app isn't
sandboxed, so it can sync any path; macOS asks for access to Documents,
Desktop, and similar folders the first time it touches them.

Run the SyncKit tests with:

```sh
swift test --package-path Packages/SyncKit
```

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

The relay is off by default. To use one, enter its `host[:port]` in the menu.
The relay must allow the build's namespace — for the deployment in
`personal-site`, add `dev.bunch.SyncThing` and `dev.bunch.SyncThing.debug` to
`RELAY_ALLOWED_NAMESPACES`.

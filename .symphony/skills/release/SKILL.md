---
name: release
description: Builds and publishes SyncThing. "Spin a build" or "release" bumps the version, runs the tests, commits, archives the Release build with Developer ID, notarizes and staples it, and reveals the app and a zip in Finder, all on this Mac. "Publish" ships that build to every installed SyncThing through Sparkle and a GitHub release. Use when the user asks to release, ship, notarize, build a distributable SyncThing, or publish an update.
---

# Releasing SyncThing

There are two separate jobs, and only the user starts the second:

- **Build** (`scripts/release.sh`): a Developer ID signed, notarized,
  stapled `SyncThing.app` and a zip of it in `~/Downloads/SyncThing-<version>/`,
  with the commit tagged `v<version>` locally. Nothing leaves this Mac.
- **Publish** (`scripts/publish.sh`): signs that zip with the Sparkle key,
  adds it to the appcast, pushes `main` and the tag, and creates the GitHub
  release at `github.com/bunchjesse/sync-thing`. Every installed SyncThing
  checks `releases/latest/download/appcast.xml`, so this is the moment the
  update reaches everyone. Only publish when the user says "publish"; a
  request to build, release, or ship a build is not one.

## Building

1. **Pick the version.** Read `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` for the `SyncThing` target with
   `GetTargetBuildSettings`. If the user didn't name a version, ask with
   `AskUserQuestion`, offering the next minor and patch versions, and
   recommend the one that fits what changed since the last `Version …`
   commit (`git log --oneline`). Rebuilding the current version is fine
   when it isn't published yet (`gh release view v<version>` fails) — move
   the old `~/Downloads/SyncThing-<version>` aside first.
2. **Set it** with `UpdateTargetBuildSetting` on the `SyncThing` target:
   `MARKETING_VERSION` to the version, and `CURRENT_PROJECT_VERSION` one
   higher than before — every build, even a rebuild of the same version.
   Sparkle compares `CURRENT_PROJECT_VERSION` (`CFBundleVersion`), not the
   version, so a build that doesn't raise it never reaches anyone. Then
   check `git diff SyncThing.xcodeproj`: Xcode rewrites the file when it
   saves and can collapse `[config=…]` settings or rename the product to
   the active configuration's name. Put those back by hand.
3. **Test**: `swift test --package-path Packages/SyncKit`. Stop if anything
   fails.
4. **Commit** everything, including the version change, as
   `Version <version>` with a short prose summary of what's new since the
   last release (`git -c user.email=jesse@bunch.dev commit -s`). The script
   refuses a dirty tree, so the release always matches a commit. Don't push;
   publishing does.
5. **Run** `.symphony/skills/release/scripts/release.sh` from the project
   root with a timeout of at least 30 minutes (`timeout: 1800`). It
   - refuses a version that's already published,
   - archives the Release configuration with `xcodebuild archive`,
   - exports it with `method developer-id` and `destination upload`, which
     sends it to Apple's notary service through Xcode's account,
   - polls `xcodebuild -exportNotarizedApp` every 30 seconds for up to 20
     minutes until Apple accepts it, which also staples the ticket,
   - checks `stapler validate`, that Gatekeeper reports
     `source=Notarized Developer ID`, the signing team, the version and
     build, and Sparkle.framework's signature,
   - copies the app and `SyncThing-<version>.zip` (made with
     `ditto --sequesterRsrc`, as Sparkle wants) to
     `~/Downloads/SyncThing-<version>/`, tags the commit `v<version>`, and
     reveals the folder in Finder.
6. **Write the release notes** to
   `~/Downloads/SyncThing-<version>/SyncThing-<version>.md`: a few Markdown
   bullets of what changed for someone using the app, from the commits
   since the last tag (`git log --oneline <last-tag>..`). Sparkle shows them
   in its update window and the GitHub release uses them too. Show them to
   the user.
7. **Report** the version and build, the commit, the folder, the Gatekeeper
   line, and that it's ready to publish when they say so.

## Publishing

Only when the user says to publish:

1. Check the notes file exists and the user has seen it.
2. **Run** `.symphony/skills/release/scripts/publish.sh <version>` from the
   project root. It
   - refuses a version already on GitHub, a missing tag, a tag that isn't on
     `main`, or a build that isn't newer than the published appcast's,
   - downloads the published `appcast.xml` and runs Sparkle's
     `generate_appcast` (from the Sparkle package's artifacts in
     DerivedData) with the `bunch.dev` key from the login Keychain, which
     signs the zip and adds an entry with the notes embedded,
   - pushes `main` and `v<version>`, creates the GitHub release with the zip
     and the new `appcast.xml`, and marks it latest,
   - checks that the live feed lists the new build.
3. **Report** the release URL. Installed copies find it within a day, or
   right away with Check for Updates….

## When it fails

- **"No Accounts" or "No signing certificate"**: Xcode isn't signed in. Ask
  the user to add their Apple Account in Xcode → Settings → Accounts (team
  `8J2AXU352N`), then rerun. Nothing else can fix this.
- **Notarization rejected**: the script prints Xcode's log, which gives
  Apple's reason (usually an unsigned nested binary or a missing hardened
  runtime). Fix that before rerunning; don't retry blindly.
- **Timed out waiting**: Apple is slow, not failing. The script prints the
  `-exportNotarizedApp` command to finish the job later; its work folder
  stays in `/tmp`.
- **Destination exists**: that version was already built. Bump the version
  or ask the user before moving the old folder.
- **Already published**: a `v<version>` tag is on GitHub, so that version is
  out. Bump the version; never move a published tag.
- **Sparkle.framework isn't properly signed**: the export didn't re-sign the
  embedded framework or its XPC services; notarization would reject it too.
- **No Sparkle tools**: `publish.sh` uses `generate_appcast` from the Sparkle
  package's artifacts in DerivedData. Build the project once with
  `BuildProject` to fetch them.
- **Couldn't list the releases or download appcast.xml**: `gh` isn't logged
  in to github.com or the network is down. The script stops rather than
  publish an appcast without the earlier builds.
- **The Keychain asks to let `generate_appcast` use the key**: the user has
  to allow it; it's the "Private key for signing Sparkle updates" item for
  account `bunch.dev`.
- **No signing key**: the key is gone from this Mac's Keychain. Never make a
  new one — installed copies only trust the public key in `Info.plist`
  (`SUPublicEDKey`). Ask the user to import their backup with Sparkle's
  `generate_keys --account bunch.dev -f <file>`.

## Notes

- This is the one place to use `xcodebuild` instead of the Xcode MCP
  tools, which can't archive or export.
- There's no `notarytool` keychain profile; notarization goes through the
  Xcode account, so `xcrun notarytool` won't work without setup.
- Releases are built from the Release configuration only, which is its
  own sync network; never ship a Debug build. Debug builds don't update
  themselves.

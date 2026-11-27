---
name: release
description: Builds a notarized SyncThing release — bumps the version, runs the tests, commits, archives the Release build with Developer ID, notarizes and staples it, and reveals the app and a zip in Finder. Use when the user asks to release, ship, notarize, or build a distributable SyncThing.
---

# Releasing SyncThing

A release is a Developer ID signed, notarized, stapled `SyncThing.app` and a
zip of it in `~/Downloads/SyncThing-<version>/`. `scripts/release.sh` does
the build and notarization; your job is the steps around it.

## Steps

1. **Pick the version.** Read `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` for the `SyncThing` target with
   `GetTargetBuildSettings`. If the user didn't name a version, ask with
   `AskUserQuestion`, offering the next minor and patch versions, and
   recommend the one that fits what changed since the last `Version …`
   commit (`git log --oneline`). Rebuilding the current version is fine
   when nothing was released under it yet — check for
   `~/Downloads/SyncThing-<version>`.
2. **Set it** with `UpdateTargetBuildSetting` on the `SyncThing` target:
   `MARKETING_VERSION` to the version, and `CURRENT_PROJECT_VERSION` one
   higher than before. Never edit `project.xcproj` by hand.
3. **Test**: `swift test --package-path Packages/SyncKit`. Stop if anything
   fails.
4. **Commit** everything, including the version change, as
   `Version <version>` with a short prose summary of what's new since the
   last release (`git -c user.email=jesse@bunch.dev commit -s`). The script
   refuses a dirty tree, so the release always matches a commit. Don't push.
5. **Run** `.symphony/skills/release/scripts/release.sh` from the project
   root with a timeout of at least 30 minutes (`timeout: 1800`). It
   - archives the Release configuration with `xcodebuild archive`,
   - exports it with `method developer-id` and `destination upload`, which
     sends it to Apple's notary service through Xcode's account,
   - polls `xcodebuild -exportNotarizedApp` every 30 seconds for up to 20
     minutes until Apple accepts it, which also staples the ticket,
   - checks `stapler validate`, that Gatekeeper reports
     `source=Notarized Developer ID`, the signing team, and the version,
   - copies the app and `SyncThing-<version>.zip` to
     `~/Downloads/SyncThing-<version>/` and reveals it in Finder.
6. **Report** the version, the commit, the folder, and the Gatekeeper line.

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

## Notes

- This is the one place to use `xcodebuild` instead of the Xcode MCP
  tools, which can't archive or export.
- There's no `notarytool` keychain profile; notarization goes through the
  Xcode account, so `xcrun notarytool` won't work without setup.
- A warning that `LSApplicationCategoryType` is missing is harmless.
- Releases are built from the Release configuration only, which is its
  own sync network; never ship a Debug build.

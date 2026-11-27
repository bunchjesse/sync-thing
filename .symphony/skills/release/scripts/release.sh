#!/bin/zsh
# Archives the Release build, notarizes it with Apple through the Xcode
# account, staples it, verifies it, tags the commit v<version>, and copies
# the app and a zip of it to ~/Downloads/SyncThing-<version>, which it then
# shows in Finder. Nothing leaves this Mac; publish.sh ships the build.
#
# Usage: release.sh [project-root]
set -euo pipefail

root=${1:-$(git rev-parse --show-toplevel)}
cd "$root"
project=SyncThing.xcodeproj
scheme=SyncThing

fail() { print -u2 "release: $*"; exit 1; }

[[ -z $(git status --porcelain) ]] || fail "the working tree has uncommitted changes; commit them first"

settings=$(xcodebuild -showBuildSettings -project $project -scheme $scheme -configuration Release 2>/dev/null)
setting() { print -r -- "$settings" | awk -v key="$1" '$1 == key && $2 == "=" { print $3; exit }'; }
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
team=$(setting DEVELOPMENT_TEAM)
[[ -n $version && -n $build && -n $team ]] || fail "couldn't read MARKETING_VERSION, CURRENT_PROJECT_VERSION, and DEVELOPMENT_TEAM"

[[ -z $(git ls-remote --tags origin "refs/tags/v$version") ]] || fail "v$version is already published; bump the version"

destination=~/Downloads/SyncThing-$version
[[ ! -e $destination ]] || fail "$destination already exists; move it away or bump the version"

work=$(mktemp -d /tmp/syncthing-release.XXXXXX)
archive=$work/SyncThing.xcarchive
print "release: building $version ($build) for team $team in $work"

xcodebuild archive -quiet -project $project -scheme $scheme -configuration Release \
    -destination 'generic/platform=macOS' -archivePath $archive -allowProvisioningUpdates

cat > $work/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

print "release: uploading for notarization"
xcodebuild -exportArchive -archivePath $archive -exportOptionsPlist $work/ExportOptions.plist \
    -exportPath $work/Upload -allowProvisioningUpdates

print "release: waiting for notarization (usually a few minutes)"
deadline=$(( SECONDS + 20 * 60 ))
until xcodebuild -exportNotarizedApp -archivePath $archive -exportPath $work/Notarized >$work/notarized.log 2>&1; do
    if ! grep -q "not ready" $work/notarized.log; then
        cat $work/notarized.log >&2
        fail "notarization failed; see the log above"
    fi
    (( SECONDS < deadline )) || fail "notarization didn't finish in 20 minutes; rerun the last step later with: xcodebuild -exportNotarizedApp -archivePath $archive -exportPath $work/Notarized"
    sleep 30
done

app=$work/Notarized/SyncThing.app
[[ -d $app ]] || fail "no app in $work/Notarized"

xcrun stapler validate $app
assessment=$(spctl -a -vvv -t exec $app 2>&1)
print -r -- "$assessment"
[[ $assessment == *"source=Notarized Developer ID"* ]] || fail "Gatekeeper doesn't see a notarized Developer ID app"
signer=$(codesign -dvv $app 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2 }')
[[ $signer == $team ]] || fail "signed by team $signer, expected $team"
built=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $app/Contents/Info.plist)
[[ $built == $version ]] || fail "the app says version $built, expected $version"
built=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" $app/Contents/Info.plist)
[[ $built == $build ]] || fail "the app says build $built, expected $build"
codesign --verify --deep --strict $app/Contents/Frameworks/Sparkle.framework || fail "Sparkle.framework isn't properly signed"

mkdir -p $destination
ditto $app $destination/SyncThing.app
ditto -c -k --sequesterRsrc --keepParent $app $destination/SyncThing-$version.zip
rm -rf $work
git tag -f "v$version" HEAD

print "release: SyncThing $version ($build) is in $destination, tagged v$version on $(git rev-parse --short HEAD)"
open -R $destination/SyncThing.app

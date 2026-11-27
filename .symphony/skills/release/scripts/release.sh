#!/bin/zsh
# Archives the Release build, notarizes it with Apple through the Xcode
# account, staples it, verifies it, and copies the app and a zip of it to
# ~/Downloads/SyncThing-<version>, which it then shows in Finder.
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
team=$(setting DEVELOPMENT_TEAM)
[[ -n $version && -n $team ]] || fail "couldn't read MARKETING_VERSION and DEVELOPMENT_TEAM"

destination=~/Downloads/SyncThing-$version
[[ ! -e $destination ]] || fail "$destination already exists; move it away or bump the version"

work=$(mktemp -d /tmp/syncthing-release.XXXXXX)
archive=$work/SyncThing.xcarchive
print "release: building $version for team $team in $work"

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

mkdir -p $destination
ditto $app $destination/SyncThing.app
ditto -c -k --keepParent $app $destination/SyncThing-$version.zip
rm -rf $work

print "release: SyncThing $version is in $destination"
open -R $destination/SyncThing.app

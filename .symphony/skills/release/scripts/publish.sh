#!/bin/zsh
# Publishes a build release.sh made: signs its zip for Sparkle, adds it to
# the appcast, pushes main and the v<version> tag, and creates the GitHub
# release that every installed SyncThing checks. Run it only when the user
# says to publish.
#
# Usage: publish.sh <version> [project-root]
# Release notes come from ~/Downloads/SyncThing-<version>/SyncThing-<version>.md.
set -euo pipefail

version=${1:?usage: publish.sh <version> [project-root]}
[[ $version =~ '^[0-9]+(\.[0-9]+)*$' ]] || { print -u2 "publish: $version isn't a version number"; exit 1; }
root=${2:-$(git rev-parse --show-toplevel)}
cd "$root"
repo=bunchjesse/sync-thing
feed=https://github.com/$repo/releases/latest/download/appcast.xml
key=~/Documents/SigningKeys/SyncThing/sparkle-private-key.txt

fail() { print -u2 "publish: $*"; exit 1; }

[[ -s $key ]] || fail "no Sparkle signing key at $key"

folder=~/Downloads/SyncThing-$version
archive=$folder/SyncThing-$version.zip
notes=$folder/SyncThing-$version.md
[[ -f $archive ]] || fail "no $archive; build it with release.sh first"
[[ -s $notes ]] || fail "no release notes at $notes"
[[ -z $(git ls-remote --tags origin "refs/tags/v$version") ]] || fail "v$version is already published"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null || fail "no local tag v$version; release.sh makes it"
git merge-base --is-ancestor "v$version" main || fail "v$version isn't on main"

build_dir=$(xcodebuild -showBuildSettings -project SyncThing.xcodeproj -scheme SyncThing -configuration Release 2>/dev/null | awk '$1 == "BUILD_DIR" { print $3; exit }')
# BUILD_DIR is DerivedData/<project>/Build/Products; packages sit beside Build.
tools=$build_dir/../../SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x $tools/generate_appcast ]] || fail "no Sparkle tools in $tools; build the project once to fetch them"

info() { unzip -p $archive SyncThing.app/Contents/Info.plist | plutil -extract $1 raw -o - -; }
[[ $(info CFBundleShortVersionString) == $version ]] || fail "$archive isn't version $version"
build=$(info CFBundleVersion)

work=$(mktemp -d /tmp/syncthing-publish.XXXXXX)
trap 'rm -rf $work' EXIT
releases=$(gh api "repos/$repo/releases?per_page=1" --jq length) || fail "couldn't list the releases on $repo"
if (( releases > 0 )); then
    gh release download -R $repo --pattern appcast.xml --dir $work || fail "couldn't download the published appcast.xml"
    published=$(grep -o '<sparkle:version>[0-9]*' $work/appcast.xml | grep -o '[0-9]*$' | sort -n | tail -1 || true)
    [[ -n $published ]] || fail "the published appcast.xml lists no builds"
    (( build > published )) || fail "build $build isn't newer than the published build $published; bump CURRENT_PROJECT_VERSION"
fi

cp $archive $notes $work/
$tools/generate_appcast --ed-key-file $key --embed-release-notes \
    --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
    --link "https://github.com/$repo" $work
grep -q "<sparkle:version>$build</sparkle:version>" $work/appcast.xml || fail "the appcast has no entry for build $build"
grep -q "releases/download/v$version/SyncThing-$version.zip\" .*sparkle:edSignature=" $work/appcast.xml || fail "the appcast entry for build $build isn't signed"
[[ -z ${published:-} ]] || grep -q "<sparkle:version>$published</sparkle:version>" $work/appcast.xml || fail "the appcast lost build $published"

print "publish: pushing main and v$version"
git push origin main "refs/tags/v$version"
gh release create "v$version" -R $repo --verify-tag --latest \
    --title "SyncThing $version" --notes-file $notes \
    $archive $work/appcast.xml

for attempt in {1..6}; do
    [[ $(curl -fsSL $feed 2>/dev/null) == *"<sparkle:version>$build</sparkle:version>"* ]] && break
    (( attempt < 6 )) || { print -u2 "publish: warning: $feed doesn't list build $build yet; check it again in a few minutes"; break; }
    sleep 10
done
print "publish: SyncThing $version ($build) is live at https://github.com/$repo/releases/tag/v$version"

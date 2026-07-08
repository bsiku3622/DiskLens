#!/bin/bash
# Build a signed release and publish it to GitHub Releases, where the app's
# in-app updater picks it up. Run locally so the build is signed with the stable
# "DiskLens Self-Signed" identity (keeps users' Full Disk Access across updates).
#
#   ./release.sh ["release notes"]
#
# The version/tag comes from Info.plist's CFBundleShortVersionString — bump it
# there before releasing.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
TAG="v$VERSION"
ZIP="DiskLens-mac.zip"
NOTES="${1:-DiskLens $VERSION}"

echo "Releasing $TAG…"
./build.sh release

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent DiskLens.app "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" --clobber
else
  gh release create "$TAG" "$ZIP" --title "DiskLens $VERSION" --notes "$NOTES"
fi

echo "Published $TAG"

#!/usr/bin/env bash
# Builds the zip and disk image for $VERSION, tags it, and publishes a GitHub release with both files under
# their versioned names and as SecureTunnels.dmg / SecureTunnels.zip. The unversioned copies make
# https://github.com/natanavra/SecureTunnels/releases/latest/download/SecureTunnels.dmg always point at the
# newest build. Running it again for an existing tag replaces the assets.
# Usage: VERSION=1.3.1 scripts/release.sh ["release notes"]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, for example VERSION=1.3.1}"
TAG="v$VERSION"
NOTES="${1:-SecureTunnels $VERSION}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit your changes before releasing." >&2
  exit 1
fi

VERSION="$VERSION" make dist
cp "build/SecureTunnels-$VERSION.dmg" build/SecureTunnels.dmg
cp "build/SecureTunnels-$VERSION.zip" build/SecureTunnels.zip

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git tag -a "$TAG" -m "SecureTunnels $VERSION"
fi
git push -q origin HEAD "$TAG"

ASSETS=("build/SecureTunnels-$VERSION.dmg" "build/SecureTunnels-$VERSION.zip" build/SecureTunnels.dmg build/SecureTunnels.zip)
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
  gh release create "$TAG" "${ASSETS[@]}" --title "SecureTunnels $VERSION" --notes "$NOTES" --latest
fi
echo "Released $TAG: https://github.com/natanavra/SecureTunnels/releases/tag/$TAG"

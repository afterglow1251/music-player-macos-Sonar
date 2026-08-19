#!/bin/bash
# Cuts a beta release of Sonar: builds the .app, stamps it with the given
# version, zips it, and (optionally) publishes a GitHub Release with the zip
# attached.
#
# The app is only ad-hoc signed (free, no Apple Developer account), so testers
# see a Gatekeeper prompt on first launch — see RELEASE_NOTES below for the
# right-click → Open instructions to hand them.
#
# Usage:
#   scripts/release.sh 0.1.0              # build + zip + publish GitHub release
#   scripts/release.sh 0.1.0 --no-publish # build + zip only (upload manually)
#
set -euo pipefail
cd "$(dirname "$0")/.."

# ── args ──────────────────────────────────────────────────────────────────
VERSION="${1:-}"
PUBLISH=1
[ "${2:-}" = "--no-publish" ] && PUBLISH=0

if [ -z "$VERSION" ]; then
    echo "✗ usage: scripts/release.sh <version> [--no-publish]"
    echo "         e.g. scripts/release.sh 0.1.0"
    exit 1
fi
VERSION="${VERSION#v}"                 # accept both 0.1.0 and v0.1.0
TAG="v$VERSION"

APP="Sonar.app"
DIST="dist"
ZIP="$DIST/Sonar-$VERSION.zip"

# ── build ─────────────────────────────────────────────────────────────────
echo "▶ Building ${APP} ${VERSION}…"
./build-app.sh "$VERSION"

# ── package ───────────────────────────────────────────────────────────────
echo "▶ Packaging ${ZIP}…"
mkdir -p "$DIST"
rm -f "$ZIP"
# ditto preserves the bundle structure and resource forks a plain `zip` mangles.
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ Wrote $ZIP"

if [ "$PUBLISH" -eq 0 ]; then
    echo "  (--no-publish) Upload it manually at:"
    echo "  https://github.com/afterglow1251/music-player-macos-Sonar/releases/new"
    exit 0
fi

# ── publish ───────────────────────────────────────────────────────────────
if ! gh auth status >/dev/null 2>&1; then
    echo "✗ gh is not authenticated. Run:  gh auth login"
    echo "  Or re-run with --no-publish and upload $ZIP by hand."
    exit 1
fi

echo "▶ Creating GitHub release ${TAG}…"
# Not --prerelease: GitHub's /releases/latest — the link README sends people to —
# skips pre-releases, so marking betas as such left that link resolving to the
# bare release list instead of a download. "beta" lives in the title instead.
gh release create "$TAG" "$ZIP" \
    --title "Sonar $VERSION (beta)" \
    --notes-file scripts/RELEASE_NOTES.md \
    --latest

echo "✓ Released. Share this link:"
echo "  https://github.com/afterglow1251/music-player-macos-Sonar/releases/tag/$TAG"

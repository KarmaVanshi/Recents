#!/bin/bash
#
# Builds Recents.app.
#
# SPM produces a bare executable, but this needs to be a real bundle: LSUIElement
# (no Dock icon) and a stable bundle identifier both live in Info.plist, and TCC
# grants Full Disk Access to bundles rather than to loose binaries.
#
#   ./build.sh            debug build
#   ./build.sh release    optimised build

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/Recents.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BINARY="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Recents"

echo "▸ Assembling bundle…"
# The app is quit and rebuilt in place, so clear out the old bundle first.
#
# Matched on identity rather than on the name "Recents": `pkill -x Recents` also
# kills any unrelated process of this user that happens to share the name.
# `osascript` addresses the bundle identifier exactly and asks the app to quit
# rather than killing it; the fallback matches the full path of *this* bundle's
# executable, which no other binary can be running under.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$ROOT/Resources/Info.plist" 2>/dev/null || echo com.recents.deck)"
EXECUTABLE="$APP/Contents/MacOS/Recents"

if pgrep -f "$EXECUTABLE" >/dev/null 2>&1; then
    echo "  (quitting running instance)"
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    sleep 0.3
    # Still there — it was mid-launch, or wedged. Now kill it, still scoped to
    # this bundle's own executable path rather than to a bare process name.
    pkill -f "$EXECUTABLE" >/dev/null 2>&1 || true
    sleep 0.2
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/Recents"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Finder attaches metadata (com.apple.FinderInfo, quarantine flags) to anything
# it looks at, and codesign --strict rejects a bundle carrying it: "resource
# fork, Finder information, or similar detritus not allowed". Clearing extended
# attributes first makes the signature verify strictly rather than only loosely.
xattr -cr "$APP" 2>/dev/null || true

echo "▸ Signing…"
# Signing identity, not ad-hoc, and the difference matters more than it looks.
#
# TCC remembers a permission grant against the bundle's *designated requirement*.
# Ad-hoc signing builds that requirement out of the binary's cdhash, which
# changes on every single build — so Screen Recording and Full Disk Access were
# silently revoked every time this script ran. Signing with a real identity makes
# the requirement `identifier "com.recents.deck" and certificate root = H"…"`,
# which has no cdhash in it and is therefore identical across rebuilds.
#
# Create a self-signed code-signing certificate of that name in the login keychain
# once and every later build reuses it. Without one this falls back to ad-hoc,
# which still produces a working app — you just re-grant permissions after every
# build.
#
# No --deep: this bundle has no nested code, and Apple discourages --deep for
# signing because it papers over nested components rather than signing them
# deliberately.
SIGNING_IDENTITY="Recents Local Signing"

# Signing is retried, because clearing the extended attributes above can be racy.
# Under a synchronising file provider — iCloud's Desktop & Documents, in
# particular — `com.apple.FinderInfo` is re-attached to the bundle within moments
# of being cleared, `codesign` then refuses with "resource fork, Finder
# information, or similar detritus not allowed", and a single attempt loses that
# race. Keeping the project outside a synced folder avoids it; the retry is here
# so that a project which does get moved into one still builds rather than
# silently falling back to an ad-hoc signature.
sign_with_identity() {
    local attempt
    for attempt in 1 2 3; do
        xattr -cr "$APP" 2>/dev/null || true
        if codesign --force --sign "$SIGNING_IDENTITY" "$APP" 2>&1; then
            return 0
        fi
        echo "  (signing attempt $attempt failed; clearing xattrs and retrying)"
    done
    return 1
}

if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
    if sign_with_identity; then
        echo "  signed as '$SIGNING_IDENTITY' — permissions survive rebuilds"
    else
        echo "" >&2
        echo "✗ Signing with '$SIGNING_IDENTITY' failed." >&2
        echo "  Refusing to leave an ad-hoc signature behind: its designated" >&2
        echo "  requirement is cdhash-based, which makes macOS revoke this app's" >&2
        echo "  Full Disk Access, Screen Recording and Accessibility grants." >&2
        exit 1
    fi
else
    codesign --force --sign - "$APP" 2>&1
    echo "  ad-hoc signed. macOS will ask for permissions again after each build;"
    echo "  create a '$SIGNING_IDENTITY' code-signing identity to stop that."
fi

# The signature is what protects the TCC grants, so it is checked rather than
# assumed. A designated requirement containing a cdhash means the identity did
# not take, and every permission the app has been granted is about to be lost.
REQUIREMENT="$(codesign -d -r- "$APP" 2>/dev/null | grep '^designated' || true)"
case "$REQUIREMENT" in
    *cdhash*)
        echo "" >&2
        echo "✗ Bundle carries a cdhash-based designated requirement:" >&2
        echo "    $REQUIREMENT" >&2
        echo "  Permissions will not survive. Not launching." >&2
        exit 1
        ;;
esac

echo ""
echo "✓ Built $APP"
echo ""
echo "  Run:     open '$APP'"
echo "  Summon:  ⇧⌘Space  (or click the clock icon in the menu bar)"
echo ""

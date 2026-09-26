#!/bin/bash
# Cut a Main Thing release: scripts/release.sh <version> [--publish] [--notes-file <file>]
#
#   1. Bump MainThingVersion to <version> and MainThingBuild by one (Version.swift, Info.plist).
#   2. Run the checks and the smoke test, then build, sign and package the app (package.sh runs build-app.sh).
#   3. Zip the app with ditto, sign the zip with Sparkle's sign_update, using the EdDSA private
#      key read at runtime from 1Password. The key goes over a pipe, never to disk or the screen.
#   4. Prepend an item for the zip to appcast.xml at the repo root.
#
# The default is a dry run: it stops before publishing, leaves the bump and the appcast in the
# working tree, and prints the exact git and gh commands. --publish runs them.
#
# Refuses to run while SUPublicEDKey in Resources/Info.plist is the placeholder, when the key in
# 1Password is missing, or when that key does not match SUPublicEDKey.
#
# The key, once, before the first release (OpenSSL 3, for example Homebrew's, for Ed25519):
#   op item create --vault "Private" --category password --title "Main Thing Sparkle EdDSA key" \
#       "password=$(openssl genpkey -algorithm ed25519 | openssl pkey -outform DER | tail -c 32 | base64)"
#   op read "op://Private/Main Thing Sparkle EdDSA key/password" | swift scripts/ed-public-key.swift
# The second line prints the public key: put it in Resources/Info.plist as SUPublicEDKey and commit.
# Keep a backup of the item. A lost key means no app can ever update again.
#
# Tests only: MAINTHING_SPARKLE_KEY_FILE reads a throwaway key from a file instead of 1Password,
# MAINTHING_DOWNLOAD_BASE points the enclosure at a local server, and build-app.sh's test
# overrides (MAINTHING_BUNDLE_ID, MAINTHING_FEED_URL, ...) pass through. Never with --publish.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEY_REF="op://Private/Main Thing Sparkle EdDSA key/password"
REPO="jonnilundy/main-thing"
PLACEHOLDER="REPLACE-WITH-PUBLIC-KEY"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
VERSION_FILE="Sources/MainThingCore/Version.swift"
PLIST="Resources/Info.plist"
APPCAST="$ROOT/appcast.xml"

fail() { echo "release: $*" >&2; exit 1; }

usage() {
    echo "usage: scripts/release.sh <version> [--publish] [--notes-file <file>]" >&2
    echo "  <version> is x.y.z, for example 0.2.0. Dry run unless --publish." >&2
    exit 2
}

NEW_VERSION=""
PUBLISH=0
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--publish" ]]; then
        PUBLISH=1
    elif [[ "$1" == "--notes-file" ]]; then
        [[ $# -ge 2 ]] || usage
        NOTES_FILE="$2"
        shift
    elif [[ "$1" == -* ]]; then
        usage
    elif [[ -z "$NEW_VERSION" ]]; then
        NEW_VERSION="$1"
    else
        usage
    fi
    shift
done
[[ -n "$NEW_VERSION" ]] || usage
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "version must look like 0.2.0, got '$NEW_VERSION'"
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || fail "no notes file at $NOTES_FILE"

# --- Preconditions. Nothing is changed before all of these pass. ---

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)
if [[ -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == "$PLACEHOLDER" ]]; then
    fail "SUPublicEDKey in $PLIST is still the placeholder. Create the key first (the header of scripts/release.sh says how), put its public key there, and commit."
fi

if [[ "$PUBLISH" == 1 ]]; then
    for var in MAINTHING_SPARKLE_KEY_FILE MAINTHING_DOWNLOAD_BASE MAINTHING_BUNDLE_ID MAINTHING_FEED_URL MAINTHING_PUBLIC_KEY MAINTHING_VERSION MAINTHING_BUILD MAINTHING_APP_OUT; do
        [[ -z "${!var:-}" ]] || fail "$var is a test override; unset it before --publish"
    done
    [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "--publish runs from main"
    command -v gh >/dev/null || fail "gh is not installed"
fi

[[ -z "${MAINTHING_APP_OUT:-}" ]] || fail "MAINTHING_APP_OUT is not supported here; the release app is build/MainThing.app"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes; commit or stash them first"
git rev-parse -q --verify "refs/tags/v$NEW_VERSION" >/dev/null && fail "tag v$NEW_VERSION exists already"

OLD_VERSION=$(sed -n 's/^public let MainThingVersion = "\([^"]*\)"$/\1/p' "$VERSION_FILE")
OLD_BUILD=$(sed -n 's/^public let MainThingBuild = \([0-9][0-9]*\)$/\1/p' "$VERSION_FILE")
[[ -n "$OLD_VERSION" && -n "$OLD_BUILD" ]] || fail "could not read MainThingVersion and MainThingBuild from $VERSION_FILE"
[[ "$NEW_VERSION" != "$OLD_VERSION" ]] || fail "$NEW_VERSION is the current version"
NEW_BUILD=$((OLD_BUILD + 1))

[[ -x "$SPARKLE_BIN/sign_update" ]] || swift package resolve >/dev/null
[[ -x "$SPARKLE_BIN/sign_update" ]] || fail "no sign_update in $SPARKLE_BIN; run swift build once"

# The private key: into a variable for the length of this script, never echoed or written.
if [[ -n "${MAINTHING_SPARKLE_KEY_FILE:-}" ]]; then
    echo "test key from MAINTHING_SPARKLE_KEY_FILE"
    PRIVATE_KEY=$(cat "$MAINTHING_SPARKLE_KEY_FILE")
else
    command -v op >/dev/null || fail "the 1Password CLI (op) is not installed"
    OP_ERR=$(mktemp)
    if ! PRIVATE_KEY=$(op read "$KEY_REF" 2>"$OP_ERR"); then
        echo "release: could not read the Sparkle signing key from 1Password at $KEY_REF" >&2
        echo "release: op said: $(tr '\n' ' ' < "$OP_ERR")" >&2
        echo "release: create the item (vault Private, item Main Thing Sparkle EdDSA key, field password), or sign in to op, then run again" >&2
        rm -f "$OP_ERR"
        exit 1
    fi
    rm -f "$OP_ERR"
fi
[[ -n "$PRIVATE_KEY" ]] || fail "the Sparkle signing key is empty"
DERIVED=$(printf '%s' "$PRIVATE_KEY" | swift scripts/ed-public-key.swift) || fail "the Sparkle signing key is not base64 of a 32 byte Ed25519 seed"
[[ "$DERIVED" == "$PUBLIC_KEY" ]] || fail "the signing key does not match SUPublicEDKey in $PLIST (its public key is $DERIVED). Updates signed with it would be refused."

# --- Bump. ---

echo "release $NEW_VERSION (build $NEW_BUILD), from $OLD_VERSION (build $OLD_BUILD)"
sed -i '' "s/^public let MainThingVersion = \".*\"$/public let MainThingVersion = \"$NEW_VERSION\"/" "$VERSION_FILE"
sed -i '' "s/^public let MainThingBuild = [0-9][0-9]*$/public let MainThingBuild = $NEW_BUILD/" "$VERSION_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

# --- Check, build, package. ---

scripts/test.sh
scripts/package.sh

APP="$ROOT/build/MainThing.app"
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[[ "$BUILT_BUILD" == "$NEW_BUILD" ]] || fail "the built app has build $BUILT_BUILD, expected $NEW_BUILD"
BUILT_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
[[ "$BUILT_KEY" == "$PUBLIC_KEY" ]] || fail "the built app carries a different SUPublicEDKey"

ZIP_NAME="MainThing-$NEW_VERSION.zip"
DMG_NAME="MainThing-$NEW_VERSION.dmg"
ZIP="$ROOT/build/$ZIP_NAME"
DMG="$ROOT/build/$DMG_NAME"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "$ROOT/build/MainThing.dmg" "$DMG"

# --- Sign the zip. ---

SIGNATURE=$(printf '%s' "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$ZIP")
printf '%s' "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --verify --ed-key-file - "$ZIP" "$SIGNATURE" >/dev/null \
    || fail "sign_update could not verify its own signature"
unset PRIVATE_KEY
LENGTH=$(stat -f %z "$ZIP")
echo "signed $ZIP_NAME ($LENGTH bytes)"

# --- Appcast: the new item goes first. ---

DOWNLOAD_BASE="${MAINTHING_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$NEW_VERSION}"
RELEASE_PAGE="https://github.com/$REPO/releases/tag/v$NEW_VERSION"
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
if [[ -n "$NOTES_FILE" ]]; then
    NOTES=$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES_FILE")
else
    NOTES="Main Thing $NEW_VERSION."
fi

ITEM=$(mktemp)
cat > "$ITEM" <<EOF
        <item>
            <title>Version $NEW_VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$NEW_BUILD</sparkle:version>
            <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>$RELEASE_PAGE</sparkle:fullReleaseNotesLink>
            <description sparkle:format="plain-text"><![CDATA[$NOTES]]></description>
            <enclosure url="$DOWNLOAD_BASE/$ZIP_NAME" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
EOF

if [[ ! -f "$APPCAST" ]]; then
    cat > "$APPCAST" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Main Thing</title>
        <link>https://raw.githubusercontent.com/jonnilundy/main-thing/main/appcast.xml</link>
        <description>Main Thing updates</description>
        <language>en</language>
    </channel>
</rss>
EOF
fi
# After the channel's own <language> line, or right after <channel> when there is none.
awk -v item="$ITEM" '
    BEGIN { while ((getline line < item) > 0) body = body line "\n" }
    { print }
    !done && /<language>/ { printf "%s", body; done = 1 }
    END { if (!done) exit 3 }
' "$APPCAST" > "$APPCAST.new" || fail "appcast.xml has no <language> line to insert after"
mv "$APPCAST.new" "$APPCAST"
rm -f "$ITEM"
xmllint --noout "$APPCAST" || fail "appcast.xml is not well formed after the insert"
echo "appcast.xml: $NEW_VERSION added first"

# --- Publish, or print how. ---

# The tag and the release go up before main, so the appcast never points at a missing zip.
COMMANDS=(
    "git add $VERSION_FILE $PLIST appcast.xml"
    "git commit -m 'Release $NEW_VERSION'"
    "git tag v$NEW_VERSION"
    "git push origin v$NEW_VERSION"
    "gh release create v$NEW_VERSION build/$ZIP_NAME build/$DMG_NAME --repo $REPO --title 'Main Thing $NEW_VERSION' --notes-file ${NOTES_FILE:-<(printf '%s\n' 'Main Thing $NEW_VERSION.')}"
    "git push origin main"
)

if [[ "$PUBLISH" == 1 ]]; then
    for command in "${COMMANDS[@]}"; do
        echo "+ $command"
        eval "$command"
    done
    echo "published $NEW_VERSION"
else
    echo
    echo "dry run: nothing is published. Built build/$ZIP_NAME and build/$DMG_NAME; the bump and appcast.xml are in the working tree."
    echo "to publish, run these (or scripts/release.sh $NEW_VERSION --publish from a clean tree):"
    for command in "${COMMANDS[@]}"; do
        echo "  $command"
    done
    echo "to undo the dry run: git checkout -- $VERSION_FILE $PLIST appcast.xml (and delete appcast.xml if it is new)"
fi

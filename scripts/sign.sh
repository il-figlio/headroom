#!/bin/zsh
# Sign Headroom with a stable self-signed identity ("Headroom Local").
# Ad-hoc signatures change every build, so Keychain can never match a
# rebuilt binary to a previous "Always Allow" consent — every rebuild and
# every keychain read re-prompts. A persistent certificate makes consent
# stick across rebuilds. The cert lives in a dedicated keychain file under
# ~/Library/Application Support/Headroom/signing, so no login-keychain
# password is ever needed. That keychain is never added to the keychain
# search list: codesign is pointed at the file with --keychain, and the
# script neither reads nor changes the search list or the login keychain.
set -eu

#
# HEADROOM_SIGN_IDENTITY selects another path:
#   -                                   ad-hoc, for verify.sh and release dry runs
#   Developer ID Application: … (TEAM)  hardened runtime + secure timestamps
# HEADROOM_SIGN_KEYCHAIN optionally names the keychain holding that identity
# (when it isn't in a keychain on the search list).
# Sparkle's nested code is signed inside-out, then the host app; it must use
# the same team as the app for library validation.
if [[ -n "${HEADROOM_SIGN_IDENTITY:-}" ]]; then
    APP="$1"
    FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
    if [[ "$HEADROOM_SIGN_IDENTITY" == "-" ]]; then
        flags=(--sign -)  # no hardened runtime: ad-hoc code has no team for library validation
    else
        flags=(--options runtime --timestamp --sign "$HEADROOM_SIGN_IDENTITY")
        [[ -n "${HEADROOM_SIGN_KEYCHAIN:-}" ]] && flags+=(--keychain "$HEADROOM_SIGN_KEYCHAIN")
    fi
    for NESTED in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
                  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
                  "$FRAMEWORK/Versions/B/Autoupdate" \
                  "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
        codesign --force --preserve-metadata=entitlements "${flags[@]}" "$NESTED"
    done
    codesign --force "${flags[@]}" "$APP"
    codesign --verify --deep --strict "$APP"
    exit 0
fi

IDENTITY="Headroom Local"
SIGNING_DIR="$HOME/Library/Application Support/Headroom/signing"
KC="$SIGNING_DIR/headroom-signing.keychain-db"
PW_FILE="$SIGNING_DIR/password"
APP="$1"

# The keychain is unlocked only while this script runs. Lock it again on every
# exit path: success, a command failing under `set -e`, or a signal (zsh runs
# the EXIT trap for a signal only when the signal's own trap calls exit).
lock_keychain() {
    [[ -f "$KC" ]] || return 0
    security lock-keychain "$KC" 2>/dev/null || true
}
trap lock_keychain EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A locked keychain reports no usable identities. Unlock an existing store
# before checking it so rebuilds keep the certificate and its keychain consent.
if [[ -f "$KC" && -f "$PW_FILE" ]]; then
    security unlock-keychain -p "$(<"$PW_FILE")" "$KC"
fi

# Self-signed local identities aren't system-trusted, so `-v` would omit
# them and accidentally recreate the certificate on every build.
if ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    mkdir -p "$SIGNING_DIR"
    PW=$(openssl rand -hex 16)
    printf '%s' "$PW" > "$PW_FILE" && chmod 600 "$PW_FILE"
    rm -f "$KC"
    security create-keychain -p "$PW" "$KC"
    security unlock-keychain -p "$PW" "$KC"
    cat > "$SIGNING_DIR/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Headroom Local
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$SIGNING_DIR/key.pem" -out "$SIGNING_DIR/cert.pem" \
        -config "$SIGNING_DIR/cert.cnf" 2>/dev/null
    security import "$SIGNING_DIR/cert.pem" -k "$KC" -T /usr/bin/codesign
    security import "$SIGNING_DIR/key.pem" -k "$KC" -P '' -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
    rm -f "$SIGNING_DIR/key.pem" "$SIGNING_DIR/cert.pem" "$SIGNING_DIR/cert.cnf"
fi

# Sign straight from the keychain file. With --keychain, codesign looks for the
# identity only in that file, so it doesn't have to be on the user's keychain
# search list. (codesign(1): the search list is consulted only to build the
# certificate chain, and a self-signed certificate is its whole chain.)
if ! codesign --force --sign "$IDENTITY" --keychain "$KC" --timestamp=none "$APP"; then
    print -u2 "sign.sh: codesign could not sign with \"$IDENTITY\" from $KC."
    print -u2 "         For a build that needs no keychain: HEADROOM_SIGN_IDENTITY=- ./scripts/build.sh"
    exit 1
fi

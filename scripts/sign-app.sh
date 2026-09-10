#!/bin/zsh
set -euo pipefail

# Keep the same cryptographic app identity across rebuilds. Do not replace this
# with an identifier-only requirement: it would also accept an unrelated signer.
APP_DIR="${1:?Usage: sign-app.sh path/to/App.app}"
SIGNING_NAME="${MAC_TOOLS_SIGNING_IDENTITY:-Mac Tools Local Signing}"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ -n "${MAC_TOOLS_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGNING_NAME" --timestamp=none "$APP_DIR"
else
    CERT_HASH="$(security find-certificate -c "$SIGNING_NAME" -Z "$SIGNING_KEYCHAIN" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}' || true)"
    if [[ -z "$CERT_HASH" ]]; then
        WORK_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/mactools-signing.XXXXXX")"
        chmod 700 "$WORK_DIR"
        trap 'rm -rf "$WORK_DIR"' EXIT
        umask 077
        cat > "$WORK_DIR/certificate.cnf" <<'CONFIG'
[req]
distinguished_name=subject
x509_extensions=extensions
prompt=no
[subject]
CN=Mac Tools Local Signing
O=Mac Tools Local Development
[extensions]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
CONFIG
        /usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -days 3650 \
            -config "$WORK_DIR/certificate.cnf" -keyout "$WORK_DIR/key.pem" \
            -out "$WORK_DIR/certificate.pem" 2>/dev/null
        export MAC_TOOLS_P12_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
        /usr/bin/openssl pkcs12 -export -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/certificate.pem" \
            -name "$SIGNING_NAME" -out "$WORK_DIR/identity.p12" \
            -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -passout env:MAC_TOOLS_P12_PASSWORD
        # Import only this signing identity. No root trust, keychain-wide ACL,
        # partition-list change, or security setting is added.
        security import "$WORK_DIR/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$MAC_TOOLS_P12_PASSWORD" -T /usr/bin/codesign
        unset MAC_TOOLS_P12_PASSWORD
        CERT_HASH="$(/usr/bin/openssl x509 -in "$WORK_DIR/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
    fi
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
    codesign --force --sign "$CERT_HASH" --keychain "$SIGNING_KEYCHAIN" --timestamp=none \
        --requirements "=designated => identifier \"$BUNDLE_ID\" and anchor H\"$CERT_HASH\"" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
codesign -d -r- "$APP_DIR"

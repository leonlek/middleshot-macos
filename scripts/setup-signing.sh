#!/usr/bin/env bash
# One-time setup: create a stable self-signed code-signing cert in the login
# keychain so TCC entries for MiddleShot survive rebuilds.
#
# How it works: codesign uses the cert's Subject CN to compute the Designated
# Requirement of the signed binary. TCC keys its grants by the DR. As long as
# the same cert is used, rebuilds keep the same DR → TCC remembers the grant.
set -euo pipefail

IDENTITY_NAME="MiddleShot Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Idempotency check
if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null \
   | grep -q "\"$IDENTITY_NAME\""; then
  echo "✓ Code-signing identity '$IDENTITY_NAME' already in $KEYCHAIN"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = req_dn
prompt             = no
x509_extensions    = v3_codesign

[req_dn]
CN = $IDENTITY_NAME

[v3_codesign]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

echo "Generating private key + self-signed cert…"
openssl req -new -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/cert.key" -out "$WORK/cert.crt" \
  -days 3650 -config "$WORK/cert.conf" 2>/dev/null

# Bundle into PKCS#12. The password is just a transport format — we throw
# it away after import. PKCS#12 reject empty passwords on macOS's openssl.
P12_PASS="transient"
# OpenSSL 3 defaults to AES-256/PBKDF2-SHA256, which macOS `security import`
# refuses. Force the legacy PBE algorithms it understands.
openssl pkcs12 -export \
  -out "$WORK/cert.p12" \
  -inkey "$WORK/cert.key" \
  -in "$WORK/cert.crt" \
  -name "$IDENTITY_NAME" \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -macalg sha1 \
  -passout "pass:$P12_PASS"

echo "Importing cert + private key into login keychain…"
security import "$WORK/cert.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASS" \
  -T /usr/bin/codesign \
  -A

echo "Adding cert to user trust as a code-signing root…"
echo "(macOS may prompt for your login password.)"
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$WORK/cert.crt"

cat <<EOF
✓ Identity '$IDENTITY_NAME' installed.

build.sh will now sign with this identity. The next 'codesign' call may pop
up a Keychain Access dialog the first time — click "Always Allow" to silence
it for future builds.
EOF

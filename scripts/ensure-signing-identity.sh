#!/bin/bash
# One local code-signing certificate. Ad-hoc signatures change every build, and
# macOS then keeps the old Device Control switch while ignoring the new app.
set -euo pipefail
NAME="Clipbook Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "\"$NAME\""; then
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cat > "$WORKDIR/cert.cfg" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[ dn ]
CN = Clipbook Local
[ codesign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = CA:false
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -days 3650 -nodes -config "$WORKDIR/cert.cfg" >/dev/null 2>&1
openssl pkcs12 -export -legacy -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -out "$WORKDIR/cert.p12" -passout pass:clipbook >/dev/null 2>&1
security import "$WORKDIR/cert.p12" -k "$KEYCHAIN" -P clipbook -T /usr/bin/codesign -A >/dev/null
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORKDIR/cert.pem" >/dev/null
security find-identity -p codesigning -v | grep -q "\"$NAME\""

#!/bin/bash
# Creates a self-signed code-signing identity "Vocab Local Signing" in a dedicated keychain
# so the Accessibility (TCC) grant survives rebuilds. Does not touch the login keychain
# and needs no GUI approval. Re-running is a no-op once it exists.
set -euo pipefail
DIR="$HOME/Library/Application Support/Vocab/signing"
KC="$DIR/vocab-signing.keychain-db"
if [ -f "$KC" ]; then echo "Already set up: $KC"; exit 0; fi
mkdir -p "$DIR"; chmod 700 "$DIR"; cd "$DIR"
umask 077
openssl rand -hex 24 > pass
cat > cert.cnf <<'C'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Vocab Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
C
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem 2>/dev/null
P="$(cat pass)"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "Vocab Local Signing" -out vocab.p12 -passout "pass:$P" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Vocab Local Signing" -out vocab.p12 -passout "pass:$P"
security create-keychain -p "$P" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$P" "$KC"
security import vocab.p12 -k "$KC" -P "$P" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$P" "$KC" >/dev/null
echo "Created identity 'Vocab Local Signing' in $KC"

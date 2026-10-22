#!/bin/bash
# One-time: a self-signed code-signing identity in its own keychain (~/Library/Lightbox/signing).
# Free, no Apple account, and no prompt: the keychain password is set here, not his login password.
set -euo pipefail
D="$HOME/Library/Lightbox/signing"; mkdir -p "$D"; cd "$D"
[ -f lightbox.keychain-db ] && { echo "exists"; exit 0; }
cat > cs.cnf <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Lightbox Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout cs.key -out cs.crt -days 3650 -config cs.cnf 2>/dev/null
openssl pkcs12 -export -inkey cs.key -in cs.crt -out cs.p12 -passout pass:lightbox -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey cs.key -in cs.crt -out cs.p12 -passout pass:lightbox
security create-keychain -p lightbox-local lightbox.keychain-db
security set-keychain-settings lightbox.keychain-db
security unlock-keychain -p lightbox-local lightbox.keychain-db
security import cs.p12 -k lightbox.keychain-db -P lightbox -A -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k lightbox-local lightbox.keychain-db >/dev/null
openssl x509 -in cs.crt -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' > sha1.txt
echo "identity $(cat sha1.txt)"

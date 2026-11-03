#!/bin/sh
# Creates the local, self-signed code-signing identity "Stages Local Signing" in the login
# keychain. No Apple involvement. With it, Stages' designated requirement is
#   identifier "dk.creativeoak.stages" and certificate root = H"<this cert>"
# instead of a per-build cdhash, so Screen Recording / Accessibility grants survive rebuilds.
#
# The first build after running this shows a keychain prompt for codesign: choose Always Allow.
set -eu

NAME="Stages Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."; exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" \
  -days 3650 -config "$dir/cert.cnf" 2>/dev/null
pass=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$NAME" \
  -out "$dir/id.p12" -passout "pass:$pass" 2>/dev/null ||
  openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$NAME" \
    -out "$dir/id.p12" -passout "pass:$pass"
security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" \
  -T /usr/bin/codesign -T /usr/bin/security
security find-identity -p codesigning | grep "\"$NAME\""

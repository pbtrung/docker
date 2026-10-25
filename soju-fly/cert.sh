#!/bin/bash
# ML-DSA-44 (FIPS 204) certs for post-quantum authentication between
# Cloudflare and nginx, all valid for 10 years, written to certs/ next to
# this script (existing files are overwritten). Two private CAs:
#
# Authenticated Origin Pulls (Cloudflare → nginx, per hostname):
# - aop-ca.key (encrypted), aop-ca.crt: the CF_AOP_CA secret; nginx checks
#   Cloudflare's client cert against it
# - aop-client.key, aop-client.crt: uploaded to Cloudflare as the AOP cert
#
# Custom Origin Trust Store (nginx → Cloudflare, needs Advanced Certificate
# Manager):
# - origin-ca.key (encrypted), origin-ca.crt: uploaded to Cloudflare's
#   Custom Origin Trust Store
# - origin.key, origin.crt: nginx's server cert, the ORIGIN_KEY and
#   ORIGIN_CERT secrets (instead of the Cloudflare Origin CA cert)
#
# Needs OpenSSL 3.5+. Cloudflare only accepts ML-DSA private keys in the
# seed-only encoding, and ML-DSA signatures need TLS 1.3.
set -euo pipefail
umask 077   # new key files readable only by you

HOST=soju.110000001.xyz
DAYS=3650
# Cloudflare's TLS client to origins only offers ML-DSA-44 (its ClientHello
# lists mldsa44 and no other ML-DSA): with an ML-DSA-65 or -87 AOP cert it
# aborts the handshake with handshake_failure, and the origin gets 525s
ALG=ML-DSA-44
# Write ML-DSA private keys as the 32-byte seed only
SEED_ONLY=(-provparam ml-dsa.output_formats=seed-only)

cd "$(dirname "$0")"
mkdir -p certs
cd certs

# Passphrase for both CA keys: use $ROOTCA_PASS if set, otherwise prompt.
if [[ -z "${ROOTCA_PASS:-}" ]]; then
  read -rsp "CA passphrase: " ROOTCA_PASS; echo
  read -rsp "Confirm passphrase: " confirm; echo
  [[ "$ROOTCA_PASS" == "$confirm" ]] || { echo "Passphrases don't match" >&2; exit 1; }
  unset confirm
fi
export ROOTCA_PASS

rm -f aop-ca.* aop-client.* origin-ca.* origin.*

# make_ca <name> <CN>: CA key, encrypted with scrypt (never written to disk
# unencrypted), and its self-signed cert
make_ca() {
  openssl genpkey "${SEED_ONLY[@]}" -algorithm "$ALG" \
    | openssl pkcs8 "${SEED_ONLY[@]}" -topk8 -scrypt -passout env:ROOTCA_PASS -out "$1.key"
  openssl req -x509 -new -key "$1.key" -passin env:ROOTCA_PASS -days "$DAYS" \
    -addext basicConstraints=critical,CA:TRUE \
    -addext keyUsage=critical,keyCertSign,cRLSign \
    -subj "/CN=$2" -out "$1.crt"
}

# make_leaf <name> <CA name> <extendedKeyUsage>: key and cert for $HOST.
# ML-DSA keys only sign: no keyEncipherment.
make_leaf() {
  cat > "$1.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=$3
subjectAltName=DNS:$HOST
EOF
  openssl genpkey "${SEED_ONLY[@]}" -algorithm "$ALG" -out "$1.key"
  openssl req -new -key "$1.key" -subj "/CN=$HOST" -out "$1.csr"
  openssl x509 -req -in "$1.csr" -CA "$2.crt" -CAkey "$2.key" -passin env:ROOTCA_PASS \
    -CAcreateserial -days "$DAYS" -extfile "$1.ext" -out "$1.crt"
  rm -f "$1.csr" "$1.ext"
}

make_ca aop-ca "$HOST AOP CA"
make_leaf aop-client aop-ca clientAuth
make_ca origin-ca "$HOST Origin CA"
make_leaf origin origin-ca serverAuth
rm -f ./*.srl
unset ROOTCA_PASS

openssl verify -x509_strict -purpose sslclient -CAfile aop-ca.crt aop-client.crt
openssl verify -x509_strict -purpose sslserver -CAfile origin-ca.crt origin.crt
for crt in aop-ca aop-client origin-ca origin; do
  printf "%-11s %s, %s\n" "$crt.crt" \
    "$(openssl x509 -in "$crt.crt" -noout -text | sed -n 's/^ *Public Key Algorithm: //p')" \
    "$(openssl x509 -in "$crt.crt" -noout -enddate)"
done
echo "Done: certs/aop-ca.{key,crt} aop-client.{key,crt} origin-ca.{key,crt} origin.{key,crt}"

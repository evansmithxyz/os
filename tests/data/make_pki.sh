#!/bin/sh
# Regenerates the test PKI in tests/data/pki/ used by tests/test_tls.py.
# TEST-ONLY keys: never trust these roots anywhere else.
#
#   root_ec   P-384 root              -> srv_ec (P-256, SAN IP:10.0.2.2 + localhost)
#                                     -> srv_wronghost (SAN DNS:other.example)
#                                     -> srv_expired (valid 2020-2021 only)
#   root_rsa  RSA-4096 root  -> int_rsa (RSA-2048, sha384) -> srv_rsa (RSA-2048, sha256)
#   localca.der = both roots, for the OS disk (tests add it as localca.der)
set -e
cd "$(dirname "$0")"
D=pki
rm -rf "$D"
mkdir "$D"
cd "$D"

cat > ext.cnf <<'EOF'
[int]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
[srv]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = IP:10.0.2.2,DNS:localhost
[wrong]
basicConstraints = critical,CA:FALSE
subjectAltName = DNS:other.example
EOF

cat > ca.cnf <<'EOF'
[ca]
default_ca = testca
[testca]
database = index.txt
new_certs_dir = .
serial = serial
default_md = sha384
policy = anything
unique_subject = no
[anything]
commonName = supplied
EOF
: > index.txt
echo 1000 > serial

root() { # name, keyopts..., subject
    name=$1; subj=$2; shift 2
    openssl req -x509 -nodes "$@" -keyout "$name.key" -out "$name.crt" -days 36500 -sha384 \
        -subj "$subj" -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}
csr() { # name, subject, keyopts...
    name=$1; subj=$2; shift 2
    openssl req -new -nodes "$@" -keyout "$name.key" -out "$name.csr" -subj "$subj" 2>/dev/null
}
sign() { # name, ca, extensions, digest
    openssl x509 -req -in "$1.csr" -CA "$2.crt" -CAkey "$2.key" -CAcreateserial -days 36500 \
        -"$4" -extfile ext.cnf -extensions "$3" -out "$1.crt" 2>/dev/null
}

root root_ec "/CN=Antigravity Test Root P-384" -newkey ec -pkeyopt ec_paramgen_curve:P-384
root root_rsa "/CN=Antigravity Test Root RSA-4096" -newkey rsa:4096

csr int_rsa "/CN=Antigravity Test Intermediate RSA" -newkey rsa:2048
sign int_rsa root_rsa int sha384

csr srv_ec "/CN=10.0.2.2" -newkey ec -pkeyopt ec_paramgen_curve:P-256
sign srv_ec root_ec srv sha384

csr srv_rsa "/CN=10.0.2.2" -newkey rsa:2048
sign srv_rsa int_rsa srv sha256
cat srv_rsa.crt int_rsa.crt > srv_rsa_chain.crt

csr srv_wronghost "/CN=other.example" -newkey ec -pkeyopt ec_paramgen_curve:P-256
sign srv_wronghost root_ec wrong sha384

csr srv_expired "/CN=10.0.2.2" -newkey ec -pkeyopt ec_paramgen_curve:P-256
openssl ca -batch -notext -config ca.cnf -cert root_ec.crt -keyfile root_ec.key \
    -in srv_expired.csr -out srv_expired.crt -startdate 20200101000000Z -enddate 20210101000000Z \
    -extfile ext.cnf -extensions srv 2>/dev/null

openssl x509 -in root_ec.crt -outform DER > root_ec.der
openssl x509 -in root_rsa.crt -outform DER > root_rsa.der
cat root_ec.der root_rsa.der > localca.der

# keep only what the tests use
rm -f ./*.csr ./*.srl index.txt* serial* ca.cnf ext.cnf ./1000.pem root_ec.der root_rsa.der
ls

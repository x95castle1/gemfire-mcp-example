#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Chunk 10c: a lab certificate authority and ONE key pair for every TLS endpoint, with nothing but
# the JDK's keytool. Run once by the one-shot `certs` service (compose.security.yaml) into ./data/certs:
#
#   ca.p12          the lab CA's private key (signs lab.p12; nothing else needs it)
#   ca.pem          the lab CA's certificate: what every CLIENT must trust (curl --cacert, NODE_EXTRA_CA_CERTS,
#                   your Mac's keychain if you want Chrome to stop warning)
#   lab.p12         key + certificate for locator, server-1..3, mcp-server, keycloak.localhost, localhost
#                   (production: one per host, from a real CA, rotated)
#   truststore.p12  the JDK's public CAs + the lab CA, for Java clients: replacing the JVM's truststore with
#                   only the lab CA would break every call to the internet (api.anthropic.com!)
#   Health.class    the TLS healthcheck for GemFire members (the image has no curl or openssl)
#
# Idempotent: does nothing when lab.p12 exists. To start over: rm -rf data/certs
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
D=/certs
P=changeit   # lab password for every store (Java's traditional default)
SAN="dns:localhost,ip:127.0.0.1,dns:locator,dns:server-1,dns:server-2,dns:server-3,dns:mcp-server,dns:keycloak.localhost"

if [ -f "$D/lab.p12" ]; then echo "certs: $D/lab.p12 exists, nothing to do"; exit 0; fi
cd "$D"
kt() { keytool -storetype PKCS12 -storepass "$P" "$@"; }

echo "certs: 1. the lab CA"
kt -genkeypair -keystore ca.p12 -alias ca -keyalg RSA -keysize 2048 -validity 3650 \
   -dname "CN=GemFire MCP lab CA" -ext bc:c -ext ku:c=keyCertSign,cRLSign   # strict clients (Python 3.13, OpenSSL 3) require key usage on a CA
kt -exportcert -keystore ca.p12 -alias ca -rfc -file ca.pem

echo "certs: 2. the lab key pair, signed by the CA (SAN: $SAN)"
kt -genkeypair -keystore lab.p12 -alias lab -keyalg RSA -keysize 2048 -validity 825 -dname "CN=gfmcp lab"
kt -certreq -keystore lab.p12 -alias lab -file lab.csr
kt -gencert -keystore ca.p12 -alias ca -infile lab.csr -outfile lab.pem -rfc -validity 825 \
   -ext "SAN=$SAN" -ext ku:c=digitalSignature,keyEncipherment -ext eku=serverAuth
kt -importcert -keystore lab.p12 -alias ca -file ca.pem -noprompt   # the chain: CA first...
kt -importcert -keystore lab.p12 -alias lab -file lab.pem           # ...then the signed reply
rm lab.csr

echo "certs: 3. a Java truststore = the JDK's CAs + the lab CA"
keytool -importkeystore -srckeystore "$JAVA_HOME/lib/security/cacerts" -srcstorepass changeit \
        -destkeystore truststore.p12 -deststoretype PKCS12 -deststorepass "$P" -noprompt >/dev/null
kt -importcert -keystore truststore.p12 -alias gfmcp-lab-ca -file ca.pem -noprompt

echo "certs: 4. compile the members' TLS healthcheck"
javac -d "$D" /security/Health.java

chmod 644 "$D"/*
echo "certs: done"; ls -l "$D"

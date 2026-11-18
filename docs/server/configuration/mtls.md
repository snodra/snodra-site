# mTLS (client certificates)

The service presents a certificate in the TLS handshake. The hub reads the service's identity from
the certificate and takes the rights from its ACL entry, exactly as for a JWT. No secret crosses the
wire and no identity provider is involved.

## Issue a certificate

The leaf must carry **exactly one URI SAN `snodra://service/<name>`** (1 to 128 characters of
`[A-Za-z0-9._-]`) and, if it has an extended key usage, `clientAuth`. With `openssl`:

```sh
# the client CA, once (keep ca.key offline)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
  -subj "/CN=Snodra hub client CA" -keyout client-ca.key -out client-ca.pem

# one certificate per service
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=billing-service" -keyout billing-service.key -out billing-service.csr
printf 'subjectAltName=URI:snodra://service/billing-service\nextendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n' > ext.cnf
openssl x509 -req -in billing-service.csr -CA client-ca.pem -CAkey client-ca.key -CAcreateserial \
  -days 7 -extfile ext.cnf -out billing-service.pem
chmod 600 billing-service.key
```

Keep the lifetime short (hours to days): there is no revocation list, so expiry is the revocation
story. In cert-manager use `uris: [snodra://service/billing-service]` and `usages: [client auth]`.

## Hub

```sh
SNODRA_SERVER_AUTH_MODE=permissive
SNODRA_SERVER_ACL_FILE=/etc/snodra/snodra.acl.toml
SNODRA_SERVER_TLS_CERT=/certs/hub.pem
SNODRA_SERVER_TLS_KEY=/certs/hub.key
SNODRA_SERVER_TLS_CLIENT_CA=/certs/client-ca.pem
SNODRA_SERVER_TLS_CLIENT_AUTH=optional     # default with a client CA; switch to required when all clients have one
```

```toml
[[service]]
name   = "billing-service"
handle = ["billing.*"]
send   = ["orders.*"]
```

- `optional` keeps token and JWT services working while certificate clients are migrated.
- `required` refuses a client without a valid certificate at the handshake.
- With `AUTH_MODE=off` the certificate authenticates nothing beyond the handshake; the hub warns.

## Kotlin client

```yaml
snodra:
  messaging:
    service-name: billing-service
    hub:
      tls:
        ca-file: /etc/snodra/hub-ca.pem
        client-cert-file: /etc/snodra/tls/billing-service.pem
        client-key-file: /etc/snodra/tls/billing-service.key
```

The key must be unencrypted **PKCS#8 PEM** (`BEGIN PRIVATE KEY`). Environment names:
`SNODRA_MESSAGING_HUB_TLS_CLIENT_CERT_FILE`, `SNODRA_MESSAGING_HUB_TLS_CLIENT_KEY_FILE`.

A client certificate implies TLS. Combining it with a static token or OAuth2 is a startup error: the
client sends no credentials with a certificate.

## Rust client

```sh
SNODRA_SERVICE_NAME=billing-service
SNODRA_SERVER_TLS_CLIENT_CERT=/etc/snodra/tls/billing-service.pem
SNODRA_SERVER_TLS_CLIENT_KEY=/etc/snodra/tls/billing-service.key
SNODRA_SERVER_TLS_CA=/etc/snodra/hub-ca.pem
```

## Rotation and expiry

Both libraries re-read the files every few seconds. A valid new pair triggers a rollover one hub at
a time, after a random delay so replicas do not roll in lockstep: deregister, drain in-flight work for
up to 10 s, close the stream, reconnect with the new pair. With two hubs no request fails; with one
hub there is a short gap.

At `notAfter` the hub closes the session with `UNAUTHENTICATED` "certificate expired" and no grace. A
service that renews ahead of time never meets it. Renew by replacing the files atomically — mount the
directory, not a single file, in a container: a single-file bind mount keeps the old inode.

Revoke by removing the service's `[[service]]` table (live sessions close at the next reload, within
5 s) and letting the certificate expire.

## Probes

A `required` hub refuses the image health check unless it presents a certificate. Give the probe its
own pair, naming a service with no rights:

```yaml
healthcheck:
  test: ["CMD", "/app/snodra-server", "--health-check",
         "--tls-client-cert", "/certs/probe.pem", "--tls-client-key", "/certs/probe.key"]
```

## Verify

```sh
curl -s -H "Authorization: Bearer $DASHBOARD_TOKEN" localhost:7001/api/v1/topology \
  | jq '.services[].instances[] | {serviceName, authKind, authenticatedService, expiresAt, certFingerprint}'
```

`authKind` reads `certificate`; `certFingerprint` is the first 8 hex characters of the leaf's
SHA-256, the only form of the certificate ever logged.

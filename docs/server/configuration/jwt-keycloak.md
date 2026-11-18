# Keycloak JWT

The service authenticates with a short-lived OAuth2 access token obtained with the
`client_credentials` grant. The hub validates the token against the realm's signing keys, requires its
`azp` to equal the service name, and takes the rights from that service's ACL entry. No long-lived
secret crosses the wire.

## Keycloak

One **confidential client per service**, with **service accounts enabled and nothing else** (no
standard flow, no direct access grants). Its **client id is the service name** — the hub compares it
to `Register.service_name` and to the ACL `[[service]]` table. Optionally add an audience mapper and set
`SNODRA_SERVER_JWT_AUDIENCE` to the same value; the hub does not require it.

Do not give a `[[service]]` table to the user-facing client: those are user-facing clients,
not services that register handlers.

## Hub

```sh
SNODRA_SERVER_AUTH_MODE=permissive
SNODRA_SERVER_ACL_FILE=/etc/snodra/snodra.acl.toml
SNODRA_SERVER_JWT_ISSUER=https://keycloak.example.com/realms/snodra
SNODRA_SERVER_JWT_AUDIENCE=snodra-server
# SNODRA_SERVER_JWT_JWKS_URI defaults to <issuer>/protocol/openid-connect/certs
```

```toml
[[service]]
name   = "billing-service"
handle = ["billing.*"]
send   = ["orders.*"]
```

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_JWT_ISSUER` | none | Exact `iss`; unset means JWT credentials are off |
| `SNODRA_SERVER_JWT_JWKS_URI` | `<issuer>/protocol/openid-connect/certs` | Where signing keys are fetched; may be an internal address while the issuer is public |
| `SNODRA_SERVER_JWT_AUDIENCE` | none | When set, the token must contain this `aud` |
| `SNODRA_SERVER_JWT_LEEWAY` | `30s` | Clock skew on `exp`, `nbf`, `iat` |
| `SNODRA_SERVER_JWT_EXPIRY_GRACE` | `30s` | How long a session survives after `exp` without a refresh |
| `SNODRA_SERVER_JWKS_REFRESH` | `5m` | Key refresh period; an unknown `kid` triggers at most one extra fetch per 30 s |
| `SNODRA_SERVER_JWT_JWKS_CA` | platform roots | Extra CA for the key fetch |

## Kotlin client

```yaml
snodra:
  messaging:
    service-name: billing-service
    hub:
      oauth2:
        token-uri: https://keycloak.example.com/realms/snodra/protocol/openid-connect/token
        client-secret-file: /run/secrets/billing-client-secret
        # client-id defaults to snodra.messaging.service-name
```

Environment forms: `SNODRA_SERVER_OAUTH2_TOKEN_URI`, `_CLIENT_ID`, `_CLIENT_SECRET`,
`_CLIENT_SECRET_FILE`, `_SCOPE`, `_CA`. A token URI together with a static token, or without any
secret, fails startup.

## Rust client

```sh
SNODRA_SERVER_OAUTH2_TOKEN_URI=https://keycloak.example.com/realms/snodra/protocol/openid-connect/token
SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE=/run/secrets/billing-client-secret
# client id defaults to SNODRA_SERVICE_NAME
```

## How the token behaves

- One token per process, shared by every hub connection, fetched single-flight.
- Renewed in the background while more than its margin remains: 20 % of its lifetime, at least 5 s,
  at most half. The new token is pushed to every live stream as `ClientMessage.credentials`, so a
  session outlives its token.
- A stream closed with `UNAUTHENTICATED` retires the cached token, so the reconnect fetches a new one.
  `PERMISSION_DENIED` (wrong `azp`, no ACL entry) does not: a new token would not help.
- If the endpoint cannot issue a token, no stream is opened; the client reports
  `no access token for <service>: <error>` and retries with the normal backoff.

## Verify

```sh
curl -s -H "Authorization: Bearer $DASHBOARD_TOKEN" localhost:7001/api/v1/topology \
  | jq '.services[].instances[] | {serviceName, authKind, authenticatedService, expiresAt}'
```

`authKind` reads `jwt`. `expiresAt` is the current token's expiry in epoch milliseconds.

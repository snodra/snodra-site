# OAuth2 / OIDC JWT

The service authenticates with a short-lived OAuth2 access token obtained with the
`client_credentials` grant. The server validates the token against the issuer's signing keys, requires
its `azp` to equal the service name, and takes the rights from that service's ACL entry. No long-lived
secret crosses the wire.

Any OAuth2/OIDC provider works: Keycloak, Entra ID, Okta, Auth0, Authentik, Dex, Zitadel. The server
itself makes no provider-specific call — it reads `iss`, `aud`, `exp`, `nbf`, `iat` and `azp` from the
token and fetches the signing keys from the JWKS endpoint.

## On the provider side

- One **confidential client per service**, using client credentials only — no browser flow, no
  direct access grants.
- The **client id is the service name**: the server compares the token's `azp` to
  `Register.service_name` and to the ACL `[[service]]` entry.
- Optionally add an audience mapper and set `SNODRA_SERVER_JWT_AUDIENCE` to the same value; the
  server does not require it.
- Do not give a user-facing client a `[[service]]` ACL entry: only services that register handlers
  need one.

??? example "If your provider is Keycloak"

    Create the client as a **confidential** client with **service accounts enabled** and nothing
    else. Its client id is the service name. The JWKS endpoint is
    `<issuer>/protocol/openid-connect/certs` and the token endpoint is
    `<issuer>/protocol/openid-connect/token`, which is what the client settings below expect.

## Server

```sh
SNODRA_SERVER_AUTH_MODE=permissive
SNODRA_SERVER_ACL_FILE=/etc/snodra/snodra.acl.toml
SNODRA_SERVER_JWT_ISSUER=https://auth.example.com/realms/snodra
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
| `SNODRA_SERVER_JWT_JWKS_URI` | `<issuer>/protocol/openid-connect/certs` | Where signing keys are fetched; may be an internal address while the issuer is public. Set it for a provider with a different JWKS path |
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
        token-uri: https://auth.example.com/realms/snodra/protocol/openid-connect/token
        client-secret-file: /run/secrets/billing-client-secret
        # client-id defaults to snodra.messaging.service-name
```

Environment forms: `SNODRA_SERVER_OAUTH2_TOKEN_URI`, `_CLIENT_ID`, `_CLIENT_SECRET`,
`_CLIENT_SECRET_FILE`, `_SCOPE`, `_CA`. A token URI together with a static token, or without any
secret, fails startup.

## Rust client

```sh
SNODRA_SERVER_OAUTH2_TOKEN_URI=https://auth.example.com/realms/snodra/protocol/openid-connect/token
SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE=/run/secrets/billing-client-secret
# client id defaults to SNODRA_SERVICE_NAME
```

## Roles

A forwarded token's roles become `ROLE_<role>` in the service. Which claim they come from is
configuration, because providers disagree:

| Provider | `security.roles-claim` |
|---|---|
| Generic, Entra ID, Auth0 (custom claim) | `roles` |
| Keycloak | `realm_access.roles` |
| Okta, Authentik, Dex (groups) | `groups` |
| OAuth2 scopes | `scope` |

```yaml
snodra:
  messaging:
    security:
      roles-claim: realm_access.roles   # the default is roles
```

The value is a dotted path into the claims; `scope` is read as the space-separated scopes, with an
optional prefix (`SCOPE_`).

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

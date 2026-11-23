# OAuth2 provider

Snodra authenticates services with OAuth2 client credentials. Each service has its own confidential
client, gets a short-lived access token and presents it when it registers. No long-lived shared secret
crosses the wire.

Nothing here is provider-specific: the server validates a standard JWT and fetches the signing keys
from the issuer's JWKS endpoint.

| Provider | Client id becomes `azp` | Roles claim | Token endpoint |
|---|---|---|---|
| Keycloak | client id | `realm_access.roles` | `<issuer>/protocol/openid-connect/token` |
| Entra ID | app registration id | `roles` | `<tenant>/oauth2/v2.0/token` |
| Okta | client id | `groups` | `<issuer>/v1/token` |
| Auth0 | client id | a custom claim you add | `<issuer>/oauth/token` |
| Authentik | client id | `groups` | `<issuer>/application/o/token/` |
| Dex | client id | `groups` | `<issuer>/token` |

## On the provider side

- One **confidential client per service**, using client credentials only — no browser flow, no
  direct access grants.
- The **client id is the service name**: the server compares the token's `azp` to
  `Register.service_name` and to the ACL entry.
- Optionally add an audience mapper and set `SNODRA_SERVER_JWT_AUDIENCE` to the same value.
- Do not give a user-facing client a `[[service]]` ACL entry; only services that register handlers
  need one.

## On the server side

```sh
SNODRA_SERVER_AUTH_MODE=permissive
SNODRA_SERVER_ACL_FILE=/etc/snodra-server/acl.toml
SNODRA_SERVER_JWT_ISSUER=https://auth.example.com/realms/snodra
SNODRA_SERVER_JWT_AUDIENCE=snodra-server
# SNODRA_SERVER_JWT_JWKS_URI defaults to <issuer>/protocol/openid-connect/certs;
# set it when your provider publishes the keys elsewhere.
```

```toml
[[service]]
name   = "billing-service"
handle = ["billing.*"]
send   = ["orders.*"]
```

Start in `permissive` mode: every violation is logged and counted in
`snodra_server_auth_violations_total`, but nothing is refused. Move to `enforce` once the count reaches
zero. The server refreshes the signing keys every `SNODRA_SERVER_JWKS_REFRESH` (5 minutes) and on an
unknown `kid`.

## On the service side

=== "Kotlin"

    ```yaml
    snodra:
      messaging:
        service-name: billing-service
        hub:
          oauth2:
            token-uri: https://auth.example.com/realms/snodra/protocol/openid-connect/token
            client-secret-file: /run/secrets/billing-client-secret
    ```

=== "Rust"

    ```sh
    export SNODRA_SERVER_OAUTH2_TOKEN_URI=https://auth.example.com/realms/snodra/protocol/openid-connect/token
    export SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE=/run/secrets/billing-client-secret
    ```

The client id defaults to the service name. A token URI together with a static token, or without a
secret, fails the startup. Prefer the `_FILE` form in containers: the secret is re-read, so a
rotation needs no restart.

## Roles for handlers

A forwarded token's roles become `ROLE_<role>` in the service. The claim they come from is
configuration, because providers disagree:

```yaml
snodra:
  messaging:
    security:
      roles-claim: realm_access.roles   # Keycloak; the default is roles
```

`scope` is accepted too, read as the space-separated scopes. A handler can then require one:

```kotlin
@CommandHandler
@RequiresAuthentication(expression = "hasRole('snodra-user')")
fun handle(command: PlaceOrder): PlaceOrderResult { /* ... */ }
```

The receiving library checks the expression before the handler runs, against the token verified with
the service's JWKS (`spring.security.oauth2.resourceserver.jwt.jwk-set-uri` or `issuer-uri`). A
guarded handler needs it: without a `JwtDecoder` the service does not start, and no forwarded token is
taken as an identity.

## Read next

- The full JWT contract, settings and failure modes:
  [OAuth2 / OIDC JWT](../server/configuration/jwt-oauth2.md).
- The other credential types: [Authentication](../server/configuration/index.md).
- Service-side security: [Kotlin configuration](../messaging/kotlin/configuration.md).

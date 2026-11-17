# Keycloak

Snodra can authenticate services with OAuth2 client credentials issued by Keycloak. Each service has
its own confidential client, gets a short-lived access token and presents it when it registers. No
long-lived shared secret crosses the wire.

## On the Keycloak side

- One **confidential client per service**, with **service accounts enabled** and no browser flows.
- The **client id is the service name**: the server compares the token's `azp` to
  `Register.service_name` and to the ACL entry.
- Optionally add an audience mapper and set `SNODRA_SERVER_JWT_AUDIENCE` to the same value.
- Do not give a user-facing client a `[[service]]` ACL entry; only services that register handlers
  need one.

## On the server side

```sh
SNODRA_SERVER_AUTH_MODE=permissive
SNODRA_SERVER_ACL_FILE=/etc/snodra-server/acl.toml
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

Start in `permissive` mode: every violation is logged and counted in
`snodra_hub_auth_violations_total`, but nothing is refused. Move to `enforce` once the count reaches
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
            token-uri: https://keycloak.example.com/realms/snodra/protocol/openid-connect/token
            client-secret-file: /run/secrets/billing-client-secret
    ```

=== "Rust"

    ```sh
    export SNODRA_SERVER_OAUTH2_TOKEN_URI=https://keycloak.example.com/realms/snodra/protocol/openid-connect/token
    export SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE=/run/secrets/billing-client-secret
    ```

The client id defaults to the service name. A token URI together with a static token, or without a
secret, fails the startup. Prefer the `_FILE` form in containers: the secret is re-read, so a
rotation needs no restart.

## Roles for handlers

A forwarded token's realm roles become `ROLE_<role>` in the service. A handler can require one:

```kotlin
@CommandHandler
@RequiresAuthentication(expression = "hasRole('snodra-user')")
fun handle(command: PlaceOrder): PlaceOrderResult { /* ... */ }
```

The receiving library checks the expression before the handler runs. Without a `JwtDecoder` it reads
a signed token without verification and warns; use `principal.verified` when a handler must insist on
a verified identity.

## Read next

- The full JWT contract, settings and failure modes:
  [Keycloak JWT](../server/configuration/jwt-keycloak.md).
- The other credential types: [Authentication](../server/configuration/index.md).
- Service-side security: [Kotlin configuration](../messaging/kotlin/configuration.md).

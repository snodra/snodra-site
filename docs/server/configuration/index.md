# Authentication

The hub can run open, or check every service's right to register types and send requests. You
choose one of four credential types, or none.

| Mode | Credential | Best for | Secret on the wire |
|---|---|---|---|
| [Anonymous](anonymous.md) | none | Local development, a trusted network segment | none |
| [Static token](token.md) | `SNODRA_SERVER_TOKEN` | A small deployment without an identity provider | yes |
| [OAuth2 / OIDC JWT](jwt-oauth2.md) | OAuth2 client credentials | A deployment with an OAuth2 provider | yes, short-lived |
| [mTLS](mtls.md) | client certificate | Zero shared secrets, a CA you already operate | no |

TLS is independent of the mode: the gRPC listener can serve TLS while authentication stays `off`.
The dashboard has its own token, separate from the service credentials.

## The mode

`SNODRA_SERVER_AUTH_MODE` is `off`, `permissive` or `enforce`. Anything but `off` needs
`SNODRA_SERVER_ACL_FILE`. The ACL is a TOML file that maps a static token's SHA-256, or a service name
for JWT and mTLS, to the type patterns it may `handle` and `send`, and whether it may `control`
processors.

```toml
[[token]]
token_sha256 = "<64 hex characters>"
service  = "billing-service"
handle   = ["billing.*"]
send     = ["orders.*", "files.GetFileMetadata"]
control  = false

[[service]]
name   = "orders-service"
handle = ["orders.*"]
send   = ["billing.*"]
```

`handle` is what the service registers; `send` is what it may request. A request outside `send` is
refused in every mode, before routing.

## Roll out without an outage

1. **Observe.** Run with `SNODRA_SERVER_AUTH_MODE=permissive` and the ACL loaded. Every violation is
   logged and counted in `snodra_server_auth_violations_total`; nothing is refused.
2. **Credential the services.** Give each one its token, JWT client or certificate, one at a time.
   Watch the violation count fall to zero.
3. **Enforce.** Set `SNODRA_SERVER_AUTH_MODE=enforce`. A service that is missing a credential now
   fails to register with a clear rejection; the hub logs it once and retries at the backoff cap.

`permissive` also refuses an `instance_id` already held by another service: handing one service's
queue and replies to another is never legitimate.

## What a service sees when it is refused

The client libraries expose the hub's last rejection instead of hiding it: Kotlin's
`HubConnection.lastRejection` and Rust's `last_rejection()`. A refusal is not an outage; the
connection keeps retrying, so fixing the token or the ACL is enough and no restart is needed.

| Refusal | Meaning |
|---|---|
| `UNAUTHENTICATED` | No credential, an unknown or expired token, or an expired certificate |
| `PERMISSION_DENIED` | The credential is for another service, a registered type is outside `handle`, or the instance id belongs to another service |
| `AccessDenied` (client error) | A request type is outside `send`; never retried |

Next: pick a mode — [anonymous](anonymous.md), [static token](token.md),
[OAuth2 / OIDC JWT](jwt-oauth2.md) or [mTLS](mtls.md).

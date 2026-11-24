---
title: "Anonymous (no authentication)"
---

`SNODRA_SERVER_AUTH_MODE=off` is the default. The hub accepts every connection, routes every request,
and keeps no notion of who sent it.

```sh
docker run --rm -p 7000:7000 -p 7001:7001 -e SNODRA_SERVER_OTLP_ENDPOINT= snodra/snodra-server:latest
```

That is the whole configuration. Services need no credential:

```yaml
# Kotlin
snodra:
  messaging:
    hub:
      address: static://localhost:7000
```

```sh
# Rust
SNODRA_SERVER_ADDRESS=http://localhost:7000
```

```sh
# Go (snodra.FromEnv)
SNODRA_SERVER_ADDRESS=localhost:7000
```

## When it is acceptable

- Local development and tests.
- A network segment where only trusted workloads can reach port 7000, with no shared tenancy.
- A migration window, before you turn on `permissive` and then `enforce`.

The hub logs a warning when the mode is `off` on a non-loopback gRPC address.

## What is still checked

Nothing about identity. Two behaviours differ from a secured hub:

- A `Register` naming an instance id held by another service **replaces** that session in `off` mode
  (in `permissive` and `enforce` it is refused).
- `hub.authStatus()` carries `NONE`; the topology has no `authKind`, `authenticatedService` or
  `expiresAt`.

TLS is independent: you can serve the gRPC port over TLS (`SNODRA_SERVER_TLS_CERT`/`_KEY`) and still
authenticate nobody. The handshake then protects the bytes, not the identity.

Next: [static token](/docs/server/configuration/token/), [OAuth2 / OIDC JWT](/docs/server/configuration/jwt-oauth2/) or [mTLS](/docs/server/configuration/mtls/).

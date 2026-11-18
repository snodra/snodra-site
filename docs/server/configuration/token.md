# Static token

Each service gets a random token; the hub's ACL file holds only its SHA-256, never the token. The
token is sent in `Register.credentials.token` on every stream and nowhere else.

This is the simplest credential for a small deployment without an identity provider.

## Hub

1. Generate a token per service and its digest:

   ```sh
   openssl rand -hex 32                 # give this to the service
   snodra-server acl hash -                # paste the token; prints its SHA-256
   ```

2. Write the ACL (`snodra.acl.toml`):

   ```toml
   [[token]]
   token_sha256 = "<the 64 hex characters>"
   service  = "billing-service"
   handle   = ["billing.*"]                 # types it may register
   send     = ["orders.*", "files.GetFileMetadata"]   # types it may request
   control  = false                         # may call the processor controls
   ```

3. Enable it:

   ```sh
   SNODRA_SERVER_AUTH_MODE=permissive \
   SNODRA_SERVER_ACL_FILE=/etc/snodra/snodra.acl.toml \
   snodra/snodra-server:latest
   ```

`permissive` evaluates and logs every rule but refuses nothing except an instance-id takeover.
Switch to `enforce` when the violation counter stays flat (see [the rollout](index.md)).

## Kotlin client

```yaml
snodra:
  messaging:
    service-name: billing-service
    hub:
      token: ${BILLING_HUB_TOKEN}
      # or: token-file: /run/secrets/snodra-server-token
```

`token-file` wins when both are set and is read again on every reconnect, so a rotation needs no
restart. The token is masked in logs and in `/actuator/env` and `/actuator/configprops`.

## Rust client

```sh
SNODRA_SERVICE_NAME=billing-service
SNODRA_SERVER_TOKEN_FILE=/run/secrets/snodra-server-token   # or SNODRA_SERVER_TOKEN
```

The file is read at startup and again before every reconnect; an empty file after a good read keeps
the last token and logs one warning. Prefer the file to the variable: a variable is visible in
`docker inspect` and `/proc`.

## What a refusal looks like

| Situation | Stream | Requests |
|---|---|---|
| No token, empty token, unknown token | closed `UNAUTHENTICATED` | — |
| Token for another service, or a registered type outside `handle` | closed `PERMISSION_DENIED` (naming the type) | — |
| Instance id held by a live session of another service | closed `PERMISSION_DENIED` | — |
| Request type outside `send` | — | `PERMISSION_DENIED`, never retried |

A closed stream is a **registration rejection**, not an outage: the client keeps retrying at the
backoff cap, exposes the message in `lastRejection` / `awaitRegistered`, and succeeds on its own
once the ACL or the token is fixed. No restart is needed on either side.

## Rotate

1. Add the new digest to the ACL, in a second `[[token]]` entry for the same service (both work).
2. Replace the token file atomically, or set the new `SNODRA_SERVER_TOKEN`.
3. The next reconnect uses it; remove the old entry from the ACL.
4. The ACL reloads on the `SNODRA_SERVER_RELOAD_INTERVAL` poll (5 s) or on `SIGHUP`.

## Verify

```sh
curl -s -H "Authorization: Bearer $DASHBOARD_TOKEN" localhost:7001/api/v1/topology | jq '.services[].instances[] | {serviceName, authKind, authenticatedService}'
```

`authKind` reads `token`; in `off` mode the field is absent. A missing token costs one `ERROR` line
per distinct message and then a `DEBUG` one, not a flood.

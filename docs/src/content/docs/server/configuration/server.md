---
title: "Server settings"
---

Every setting is an environment variable **and** a flag: `SNODRA_SERVER_LISTEN` is `--listen`, and a flag
wins over the variable. An empty value means *unset* for all of them; `SNODRA_SERVER_OTLP_ENDPOINT` is
unset by default, so a server exports no telemetry until you name a collector. Durations accept `30`,
`30s`, `500ms` and `5m`.

`snodra-server --help` lists the flags; `snodra-server --version` prints the release.
The common ones, with their variables:

| Flag | Variable | Default |
|---|---|---|
| `--listen <addr>` | `SNODRA_SERVER_LISTEN` | `0.0.0.0:7000` |
| `--http-listen <addr\|"">` | `SNODRA_SERVER_HTTP_LISTEN` | `0.0.0.0:7001`; empty disables it |
| `--id <id>` | `SNODRA_SERVER_ID` | hostname + 8 random hex digits |
| `--log <filter>` | `SNODRA_SERVER_LOG` | `info` |
| `--log-format <text\|json>` | `SNODRA_SERVER_LOG_FORMAT` | `text`; `json` for a collector |
| `--otlp-endpoint <url\|"">` | `SNODRA_SERVER_OTLP_ENDPOINT` | off |
| `--auth-mode <off\|permissive\|enforce>` | `SNODRA_SERVER_AUTH_MODE` | `permissive` |
| `--acl-file <path>` | `SNODRA_SERVER_ACL_FILE` | none |
| `--dashboard-token-file <path>` | `SNODRA_SERVER_DASHBOARD_TOKEN_FILE` | none |
| `--write-token-file <path>` | `SNODRA_SERVER_DASHBOARD_WRITE_TOKEN_FILE` | none |
| `--jwt-issuer <iss>`, `--jwt-jwks-uri <url>`, `--jwt-audience <aud>` | `SNODRA_SERVER_JWT_*` | none |
| `--tls-cert <pem>` `--tls-key <pem>` | `SNODRA_SERVER_TLS_CERT` / `_TLS_KEY` | none |
| `--http-tls-cert <pem>` `--http-tls-key <pem>` | `SNODRA_SERVER_HTTP_TLS_CERT` / `_KEY` | the gRPC pair |
| `--grafana-url <url>` | `SNODRA_SERVER_GRAFANA_URL` | none |
| `--peers <url[,url]>` | `SNODRA_SERVER_PEERS` | none |

```sh
snodra-server --listen 0.0.0.0:7000 --log-format json --auth-mode enforce --acl-file /etc/snodra/acl.toml
```

The rest of the settings on this page are environment variables only.

### Probing a hub

`--health-check` and `--topology` talk to the local hub by default: the port of `SNODRA_SERVER_LISTEN`
(7000) on `127.0.0.1`, or whatever `--listen` names, so a hub started with `--listen 0.0.0.0:7010` is
found with the same flag:

```sh
snodra-server --listen 0.0.0.0:7010 --log-format json     # one terminal
snodra-server --health-check --listen 0.0.0.0:7010        # another: SERVING
snodra-server --topology --listen 0.0.0.0:7010
```

`--address host:port` reaches a hub elsewhere. On macOS port 7000 belongs to AirPlay, so a probe that
answers with an HTTP/2 frame error is talking to it — pass `--listen` or `--address`.

## Identity and listeners

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_ID` | hostname + `-` + 8 random hex digits | identifies this hub process in `RegisterAck.hub_id` and the topology (`hubId`) |
| `SNODRA_SERVER_LISTEN` | `0.0.0.0:7000` | gRPC bind address |
| `SNODRA_SERVER_HTTP_LISTEN` | `0.0.0.0:7001` | HTTP bind address for the dashboard and its API; empty disables the HTTP listener |
| `SNODRA_SERVER_OTLP_ENDPOINT` | none | OTLP gRPC endpoint for traces and metrics; unset exports nothing |
| `SNODRA_SERVER_LOG` | `info` | `tracing` filter, for example `snodra_server=debug,info` |
| `SNODRA_SERVER_JWKS_REFRESH` | `5m` | how often the signing keys are fetched again (an unknown `kid` fetches at most once per 30 s on top); positive |

## Timeouts

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_DEFAULT_TIMEOUT_MS` | `5000` | used when `Request.timeout_ms` is 0 and the type has no override |
| `SNODRA_SERVER_MAX_TIMEOUT_MS` | `60000` | upper clamp for `Request.timeout_ms` on types without an override |
| `SNODRA_SERVER_TIMEOUT_OVERRIDES` | none | per-type timeouts, `type=ms,type=ms` (for example `files.Upload=120000`); see Request timeouts |
| `SNODRA_SERVER_HEARTBEAT_TIMEOUT` | `10s` | dead-instance threshold (`10`, `10s` or `500ms`) |
| `SNODRA_SERVER_MAX_STREAM_DURATION` | `10m` | a streaming query open for longer ends with `ReplyEnd{error = CANCELLED}` and its handler is cancelled; at least `1s` |
| `SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION` | `0` | a subscription open for longer ends with `ReplyEnd{error = CANCELLED}` and its targets are cancelled; `0` is unlimited, otherwise at least `1s` |
| `SNODRA_SERVER_HANDSHAKE_TIMEOUT` | `10s` | a new `Connect` stream must send `Register` within this (`10`, `10s` or `500ms`) |

## Heartbeats, sessions and flow control

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_HEARTBEAT_INTERVAL` | `3s` | heartbeat period announced to clients in `RegisterAck`; `SNODRA_SERVER_HEARTBEAT_TIMEOUT` must be at least twice it |
| `SNODRA_SERVER_QUEUE_CAPACITY_PER_INSTANCE` | `10000` | requests queued for one instance before new ones are rejected |
| `SNODRA_SERVER_QUEUE_BYTES_PER_INSTANCE` | `64MiB` | encoded bytes queued for one instance before new requests are rejected (`B`, `KiB`, `MiB`, `GiB`, or plain bytes) |
| `SNODRA_SERVER_QUEUE_BYTES_TOTAL` | `512MiB` | encoded bytes queued over all instances together before new requests are rejected (reason `queue_bytes_total`; same units) |
| `SNODRA_SERVER_OWNER_GRACE` | `60s` | keep type ownership after the last instance leaves |
| `SNODRA_SERVER_SUBSCRIPTION_BUFFER` | `256` | updates of a subscription the hub holds while its sender owes credit; one more ends it with `ReplyEnd{error = RESOURCE_EXHAUSTED}`; positive |
| `SNODRA_SERVER_MAX_SUBSCRIPTIONS_PER_INSTANCE` | `1024` | subscription targets one handler instance serves at once; a subscription that would exceed it on any target is refused with `Error{RESOURCE_EXHAUSTED}` before anything is sent; positive |
| `SNODRA_SERVER_SESSION_BUFFER` | `1024` | per-session outbound buffer, in messages |

## Dashboard and topology

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_DASHBOARD_ENABLED` | `true` | serve the dashboard (`/ui/`) and its API (`/api/v1/`, the processor controls included) on the HTTP port and keep the edge statistics; `false` makes them 404 (`true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`) |
| `SNODRA_SERVER_GRAFANA_URL` | none | Grafana base URL the dashboard links to; must be `http://` or `https://` without user info (`user:password@` is rejected at startup, as the link is served unauthenticated) |
| `SNODRA_SERVER_EDGE_STATS_MAX_EDGES` | `10000` | cap on `(sender service, type)` edges kept for the dashboard graph; at the cap the least recently used go first |
| `SNODRA_SERVER_EDGE_STATS_WINDOW` | `5m` | sliding window of the edge statistics, at least `10s` |
| `SNODRA_SERVER_PEERS` | none | the other hubs' dashboard base URLs as the operator's browser reaches them, comma-separated, for example `http://localhost:7001,http://localhost:7011` (this hub's own URL may be listed; the page skips it by hub id). Each must be `http://` or `https://` with a host and optional port, no user info, no path beyond `/`; normalised to origins (lowercase, default port dropped), duplicates removed, at most 16; anything else stops the hub at startup. See Multiple hubs |

## Processor control

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_CONTROL_TIMEOUT` | `10s` | how long a control call waits for an instance's answer (pause, resume, a reset's prepare and finish, dead letters) |
| `SNODRA_SERVER_RESET_TIMEOUT` | `120s` | how long the instance that executes a reset may take |

## Authentication, TLS and tokens

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_AUTH_MODE` | `off` | `off`, `permissive` (evaluate every rule, log and count violations, allow everything) or `enforce` (refuse them); anything but `off` needs `SNODRA_SERVER_ACL_FILE`. See Security |
| `SNODRA_SERVER_ACL_FILE` | none | TOML ACL: SHA-256 of each static token to its service, `handle` and `send` patterns; reloaded when it changes |
| `SNODRA_SERVER_JWT_ISSUER` | none | the `iss` a JWT credential must carry, exact match; unset: JWT credentials are off and refused as "not configured". Needs an auth mode other than `off`. See Security |
| `SNODRA_SERVER_JWT_JWKS_URI` | `<issuer>/protocol/openid-connect/certs` | where the signing keys are fetched from (the default OpenID Connect path; there is no discovery); separate from the issuer so a hub can fetch internally and validate the public issuer. `http://` warns once unless loopback or a single-label name. Without an issuer it is a startup error |
| `SNODRA_SERVER_JWT_AUDIENCE` | none | when set, a JWT's `aud` (string or array) must contain it |
| `SNODRA_SERVER_JWT_LEEWAY` | `30s` | clock skew tolerated on `exp`, `nbf` and `iat` |
| `SNODRA_SERVER_JWT_EXPIRY_GRACE` | `30s` | how long after `exp` a JWT session stays open without a refresh |
| `SNODRA_SERVER_JWT_JWKS_CA` | none | an extra CA (PEM) trusted for the key fetch, on top of the platform roots; an unreadable file is a startup error whatever the URI scheme (unused, with a warning, over `http://`) |
| `SNODRA_SERVER_RELOAD_INTERVAL` | `5s` | how often the ACL and the TLS pairs are checked for changes; SIGHUP reloads at once |
| `SNODRA_SERVER_TLS_CERT`, `SNODRA_SERVER_TLS_KEY` | none | PEM pair of the gRPC listener, both or neither; the listener then accepts TLS only |
| `SNODRA_SERVER_TLS_CLIENT_CA` | none | PEM bundle of the CAs whose client certificates the gRPC listener accepts (mutual TLS); needs the gRPC pair; an unreadable or empty bundle is a startup error; reloaded with the certificates (a bad file keeps the previous CAs, counted); the HTTP port never asks for a certificate; with `AUTH_MODE=off` it authenticates nothing beyond the handshake (startup warning). See Security |
| `SNODRA_SERVER_TLS_CLIENT_AUTH` | `optional` (when the CA is set) | `optional`: no certificate is fine (token or JWT), one that is presented must verify; `required`: a client without a valid certificate fails the handshake. Without `SNODRA_SERVER_TLS_CLIENT_CA` it is a startup error |
| `SNODRA_SERVER_HTTP_TLS_CERT`, `SNODRA_SERVER_HTTP_TLS_KEY` | the gRPC pair | PEM pair of the HTTP listener |
| `SNODRA_SERVER_TLS_HANDSHAKE_TIMEOUT` | `5s` | a TLS handshake that takes longer is dropped; positive |
| `SNODRA_SERVER_TLS_HANDSHAKES_PER_IP` | `32` | TLS handshakes in progress at once from one peer IP; more are dropped at once; `0` removes the cap |
| `SNODRA_SERVER_DASHBOARD_TOKEN` | none | at least 16 characters; when set `/api/v1/*` and the gRPC `Topology` call need `Authorization: Bearer <token>` |
| `SNODRA_SERVER_DASHBOARD_TOKEN_FILE` | none | a file holding the dashboard token (trailing newline trimmed, same rules as the variable); read at startup and again on the reload poll, so a rotation needs no restart. Wins over `SNODRA_SERVER_DASHBOARD_TOKEN` when both are set (as `SNODRA_MESSAGING_HUB_TOKEN_FILE` does in the client libraries). An unreadable or invalid file stops the hub at startup; at a reload it keeps the previous token and logs an error. Prefer it to the variable: an environment variable shows in `docker inspect` and `/proc` |
| `SNODRA_SERVER_DASHBOARD_WRITE_TOKEN`, `SNODRA_SERVER_DASHBOARD_WRITE_TOKEN_FILE` | none | at least 16 characters; the processor controls' token (`Authorization: Bearer <token>` on the mutating calls), which also reads what the dashboard token reads; the file variant is read and reloaded like `SNODRA_SERVER_DASHBOARD_TOKEN_FILE`. Equal to the dashboard token (whatever the source) is a config error at start, and a reload that would make them equal keeps both previous tokens. Unset and no ACL entry with `control = true`: the controls answer 403 `controls are disabled` |

## Event browser

The server reads no event store: the [event browser](/docs/server/event-browser/) is the `snodra-event-browser`
add-on, with [its own settings](/docs/tools/event-browser/#settings). The server's side:

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_EVENT_BROWSER_PAYLOADS` | `false` | serve event payloads (record detail, `q`) to a request that presents the dashboard or write token (a token must be configured too) |
| `SNODRA_SERVER_EVENT_MAX_TAILS` | `4` | event tails open at once on this hub, 1 to 1024; one more is 429 |

`SNODRA_SERVER_KAFKA_BOOTSTRAP`, `SNODRA_SERVER_EVENT_TOPICS`, `SNODRA_SERVER_EVENT_SEARCH_MAX_SCANNED`,
`SNODRA_SERVER_EVENT_SEARCH_MAX_RESULTS`, `SNODRA_SERVER_EVENT_SEARCH_TIMEOUT`, `SNODRA_SERVER_EVENT_MAX_SEARCHES`,
`SNODRA_SERVER_EVENT_TAIL_DURATION` and `SNODRA_SERVER_GROUP_LAG_INTERVAL` are no longer read; each one still set is
a startup warning.

## Startup checks

Startup fails on a malformed `SNODRA_SERVER_TIMEOUT_OVERRIDES`, when `SNODRA_SERVER_HEARTBEAT_TIMEOUT` is less than twice `SNODRA_SERVER_HEARTBEAT_INTERVAL`, on a malformed ACL file, on an unreadable TLS pair, and on a dashboard token shorter than 16 characters.

On macOS, port 7000 is used by Control Center (AirPlay Receiver); set `SNODRA_SERVER_LISTEN=0.0.0.0:7002` or disable it.

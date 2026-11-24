---
title: "Topology"
---

What the hub knows about its services, types and instances, and how fresh that picture is.

## Topology view

The hub can show who is connected right now: every service with its live instances, which command
and query types each instance handles, who owns each type, and how many requests are in flight
(as handler and as sender). It never contains payloads or headers. The same snapshot is served
three ways:

```sh
grpcurl -plaintext -import-path proto -proto hub.proto localhost:7000 snodra.hub.v1.Hub/Topology   # gRPC, same port as Connect
curl localhost:7001/api/v1/topology                            # HTTP JSON (the dashboard API)
snodra-server --topology [--json]                                 # CLI inside the container
```

```sh
docker exec snodra-server /app/snodra-server --topology
docker exec snodra-server /app/snodra-server --topology --json
```

- `GET /api/v1/topology` is served on `SNODRA_SERVER_HTTP_LISTEN` (camelCase fields, `kind` as
  `COMMAND` or `QUERY`) with the rest of the [dashboard API](/docs/server/dashboard/). Besides the dashboard
  paths (`/`, `/ui`, `/ui/...`, `/api/v1/...`) every path is 404, and with
  `SNODRA_SERVER_DASHBOARD_ENABLED=false` every path is: the gRPC call and the CLI remain.
  the HTTP endpoint is a second port (7001), because the gRPC port speaks only
  HTTP/2 gRPC. An empty `SNODRA_SERVER_HTTP_LISTEN` disables it.
- `snodra-server --topology` prints a table (`--json` prints the JSON). It probes `127.0.0.1` on the
  port of `SNODRA_SERVER_LISTEN` (or `--address host:port|https://host:port`) with a 3 s timeout, over
  TLS as `--tls-ca <pem>`, an `https://` address or the environment's TLS setting say, with
  `SNODRA_SERVER_DASHBOARD_TOKEN` from its environment when the hub has one. Exit codes: 0 success, 1 failure (hub
  unreachable or timeout), 2 usage error (unknown or conflicting flags; usage goes to stderr).
  With nothing connected it prints `no services connected` and a totals line.
- Without `SNODRA_SERVER_DASHBOARD_TOKEN` the topology has no authentication, like the rest of the
  port-7000 surface, except that with `SNODRA_SERVER_AUTH_MODE=enforce` the gRPC call needs a service
  credential: an ACL token, a JWT of a service with a `[[service]]` table, or a client certificate of
  one (`permissive` lets a call without one through, counted as `topology_unauthenticated`).
- With `SNODRA_SERVER_DASHBOARD_TOKEN` set, the gRPC call needs a credential in every mode, `permissive`
  included: the dashboard token, or, in `permissive` and `enforce`, one of those service credentials
  (`off` reads no ACL, so there only the dashboard token passes); anything else is `UNAUTHENTICATED`.
  `GET /api/v1/topology` needs the dashboard token or the write token (see [Security](/docs/server/configuration/)).
- The hub has no gRPC server reflection, hence the `-proto` flags. grpcurl's proto-JSON prints
  int64 as strings and omits default values, so its output differs textually from
  `curl :7001/api/v1/topology`.

### Snapshot fields

Top level:

| Field | Type | Meaning |
|---|---|---|
| `hubId` | string | `SNODRA_SERVER_ID` |
| `hubStartedAtMs` | int64 | hub start, epoch milliseconds |
| `nowMs` | int64 | snapshot time, epoch milliseconds |
| `heartbeatTimeoutMs` | int64 | the configured `SNODRA_SERVER_HEARTBEAT_TIMEOUT`, in ms |
| `services` | list | one entry per service with at least one live session |
| `types` | list | one entry per owned type, including orphaned ones |
| `totals` | object | `services`, `instances`, `commandTypes`, `queryTypes`, `inFlight`, `queued` (all counts; `inFlight` includes queued requests) |

`services[]`: `serviceName` (string) and `instances[]`:

| Field | Type | Meaning |
|---|---|---|
| `instanceId` | string | instance id from `Register` |
| `connectedSinceMs` | int64 | when the session started, epoch ms |
| `lastHeartbeatAgeMs` | int64 | time since the last heartbeat, ms |
| `stale` | bool | `lastHeartbeatAgeMs` > a third of the eviction threshold (see below) |
| `inFlightAsHandler` | uint32 | requests currently being handled by this instance |
| `inFlightAsSender` | uint32 | requests this instance sent that have no terminal message yet |
| `commandTypes` | list of string | command types this instance registered |
| `queryTypes` | list of string | query types this instance registered (shared ones included) |
| `sharedQueryTypes` | list of string | the query types it registered as shared (`Register.shared_query_types`) |
| `clientVersion` | string | `Register.client_version`, for example `snodra-messaging/0.1.0`; empty when the client sent none |
| `permitsAvailable` | uint32 | permits left: requests the hub may still forward before the next `Permits` |
| `queued` | uint32 | requests waiting in the hub's queue for this instance |
| `loadFactor` | uint32 | `Register.load_factor` as applied (0 reads as 100) |
| `tags` | map | `Register.tags` |
| `connectedHubIds` | list of string | `InstanceStatus.connected_hub_ids` as last reported: the hubs the instance holds a stream to; empty when never reported |
| `statusAgeMs` | int64 | time since that report, ms; `-1` when never reported |
| `processors` | list | `InstanceStatus.processors` of that report, as kept (see [Event processors](/docs/server/event-processors/)): `name`, `groupId`, `topic`, `state`, `partitions[]` (`partition`, `position`, `committed`, `highWatermark`, `lag`), `processedTotal`, `failedTotal`, `deadLetters`, `lastError`, `lastErrorAtMs`, `eventTypes`, `deadLetterMode`; `[]` when never reported |

`types[]`:

| Field | Type | Meaning |
|---|---|---|
| `type` | string | the command or query type name |
| `kind` | string | `COMMAND` or `QUERY` |
| `ownerServices` | list of string | every owning service, sorted (one for an exclusive type) |
| `shared` | bool | a shared query type: many services may own it |
| `liveInstances` | uint32 | live instances of the owner (of all owners) that registered it |
| `orphaned` | bool | the owner has no live instance (ownership is held during the grace period) |
| `orphanedForMs` | int64 | how long it has been orphaned, ms; 0 when not orphaned |

`totals.inFlight` counts requests in the router, so it can differ from the per-instance sums when
a sender or handler is already gone. A scatter-gather counts once in `inFlight` and in its
sender's `inFlightAsSender`, and once per target in each handler's `inFlightAsHandler`.

### Consistency

A snapshot is three sequential reads (sessions, then registry, then router), each under its own
lock and never nested. It is not a single atomic cut: a request or a disconnect can land between
reads. Sessions are the base set: an instance appears only if it has a live session, and its
types and in-flight counts are attached by instance id (empty or zero when absent).

### Staleness

an instance is `stale` when its last heartbeat is older than a third of the
eviction threshold (`SNODRA_SERVER_HEARTBEAT_TIMEOUT`).
It is still connected and still receives requests; the flag is an early warning before the hub
evicts it at the full timeout. A brief `stale: true` right before a heartbeat arrives is normal.

### Orphaned types

when the last instance of a service leaves, its types stay in `types` with
`orphaned: true` and a growing `orphanedForMs` until `SNODRA_SERVER_OWNER_GRACE` expires and the
sweep removes them. Requests for an orphaned type fail with `NO_HANDLER`.

### Register rejections

two additions to the registry rules.

- A type listed under both `command_types` and `query_types` in one `Register` is rejected with
  `INVALID_ARGUMENT`.
- Registering a type under a different kind than its current owner uses (for example a query
  type that the owner holds as a command) is rejected with `ALREADY_EXISTS`. A type's kind cannot
  change while it is owned; change it only after every instance of the owner has left and the
  owner grace sweep has removed the type.
- Shared query types (`Register.shared_query_types`): a type registered
  exclusive by one registrant and shared by another (even of the same service) fails the later
  `Register` with `ALREADY_EXISTS`; a type listed as shared and as a command or exclusive query in
  one `Register` is `INVALID_ARGUMENT`. Like a kind, the flag changes only once the type is gone.

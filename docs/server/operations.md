# Operations

High availability, graceful shutdown and upgrades.

## High availability

Decision record: ADR 0016. Run two or
more hubs; they never talk to each other. Each hub is exactly the hub described above: its
registry holds the instances with a stream to it, and it routes only to them. Availability comes
from every service instance connecting to every hub with the same registration, so any hub can
route any request while at least one is up.

**Hub side (shipped):**

- A client sends `ClientMessage.status` (`InstanceStatus{connected_hub_ids, handlers_in_flight}`)
  every 5 s on each stream. The hub keeps the latest report per session (replaced by each,
  dropped with the session; at most 64 hub ids of at most 128 bytes, empty, over-long and
  duplicate ids ignored) and shows it as `connectedHubIds` and `statusAgeMs` in the
  [topology](https://snodra.damoreira.com/server/topology/).
- `SNODRA_SERVER_PEERS` lists the hubs' dashboards; the page reads every peer's
  `/api/v1/topology` in the browser and, under "All hubs", merges them and flags where the
  reachable hubs disagree: an instance missing on a hub, an instance with different types on
  different hubs, a type owned by different services on different hubs, an instance whose
  reported hubs omit a reachable hub. An unreachable peer is shown as unreachable, not as a
  disagreement. The traffic graph and the Types page stay per hub.
- The sandbox runs two hubs: `hub` (gRPC `localhost:7002`, dashboard `http://localhost:7001/`) and
  `hub-2` (gRPC `localhost:7012`, dashboard `http://localhost:7011/`), each listing both
  dashboards as peers ([07-local-development.md](quickstart.md)).

**Client side** (both libraries, per ADR 0016): one connection per hub (deduplicated by
`hub_id`), identical registration on each, unkeyed requests round-robin over acknowledged hubs,
keyed commands rendezvous-hashed over `(routing key, hub_id)` to one hub, replies on the arrival
stream, permits split `ceil(max-concurrent-handlers / N)`, unsent requests retried on another hub,
sent ones failed with `HubConnectionLost`, `InstanceStatus` every 5 s. Streaming queries and
subscriptions are bound to one hub. Rules shared by both libraries:

- **Permit top-up.** N counts the hubs that are live or still on their first connect attempt (a
  first attempt that fails counts as gone). When N shrinks (a hub went down, failed its first
  attempt, was parked as a duplicate or was drained), every live stream gets
  `Permits{count = max(0, ceil(max / N) - offered), grant = ceil(max / N)}`, offered = what that
  stream already offered the hub (its `initial_permits` plus earlier top-ups). The grant raises
  the hub's cap on the session to the new share before the count is added, so with two hubs the
  survivor of an outage serves at full capacity and repeated flaps never add up. A hub that joins
  or returns gets `ceil(max / N)` initial permits on its new stream. Nothing is ever revoked; each instance's local handler bound
  stays `max-concurrent-handlers`.
- **Hub id.** `RegisterAck.hub_id`; for an empty `hub_id`, the target id: the bare
  `host:port` (`static://`, and in Rust `http(s)://`, stripped; a resolved IPv6 address as
  `[ip]:port` without zone).
- **One address family.** A `dns:///` answer is reduced to its IPv4 addresses when it has any,
  else its IPv6 ones, without repeats: a dual-stack name lists every hub under both families,
  and two streams to one hub with the same instance id replace each other (this hub keeps one
  session per instance id).
- **Duplicates.** The first target to acknowledge a `hub_id` owns it while it is kept, live or
  reconnecting; a later target answering the same id is closed and parked (its `Register` has
  already replaced the owner's session, the owner reconnects) and is retried only once the owner
  is gone. Neither library dedupes before connecting, so two targets of one hub cost one eviction
  at startup, then settle. A DNS address that comes back while its connection is still draining revives that
  connection instead of opening a second stream.
- **Writes still queued on the client** when a stream breaks: the Kotlin client never wrote them,
  so it sends them to another hub; the Rust crate counts what sits in its 256-deep outbound buffer
  as written and fails it with `HubConnectionLost`. The libraries may differ here; see each README.

**Client configuration.** The existing address setting takes the list; there is no separate key:

| | Kotlin starter | Rust crate |
|---|---|---|
| Hubs | `kraken.messaging.hub.address` (`SNODRA_SERVER_ADDRESS` in the services' yaml) | `SNODRA_SERVER_ADDRESS` (`Config.hub_address`) |
| Forms | `host:port` (`static://` optional), a comma-separated list `static://hub:7000,hub-2:7000` (`static://` optional per entry), or one `dns:///name:port` (port required, alone) re-resolved every 30 s | the same (`http(s)://` also accepted per entry) |
| Status period | `kraken.messaging.hub.status-interval`, default `5s`; also sent on every change of the live hubs | `SNODRA_SERVER_STATUS_INTERVAL_MS`, default `5000`; on the period only |
| Default | `static://snodra-server:7000` (one hub) | `static://snodra-server:7000` (one hub) |

One target is the single-hub setup. The keyed-request hash, the permit split and top-up, and the
address-family rule are identical in both libraries ([02-messaging.md](https://snodra.damoreira.com/messaging/)). In the sandbox
every service uses `static://hub:7000,hub-2:7000`.

## Graceful shutdown

On SIGTERM or Ctrl-C the hub sets health to `NOT_SERVING`, stops accepting new streams, lets the
server drain, flushes telemetry and exits. The HTTP listener stops on the same signal; open
dashboard streams end within half a second.

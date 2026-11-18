# Routing and ownership

How the hub decides which live instance receives a request, and what happens when instances come and go.

## Registry model

```text
registry
├── types: Map<type_name, Owner>
│     Owner { kind: COMMAND | QUERY, shared, services: Map<service_name, { holders, orphaned_at }>,
│             rotation (shared types) }
└── services: Map<service_name, Service>
      Service { instances: Vec<InstanceId>, ring: ConsistentHashRing<InstanceId> (weighted), rotation }
  instances: Map<InstanceId, { service, types, placement: { load_factor, tags } }>

sessions: Map<InstanceId, Session>
  Session { context, service_name, stream_tx, last_heartbeat,
            client_version, placement, principal, auth }

flows: Map<InstanceId, Flow>
  Flow { session token, permits, cap, queue (priority, then age), assigned }

pending: Map<request_id, Pending>
  Pending = Unary { context, sender + session token + service, handler + session token,
                    deadline, span, part_of (scatter-gather target) }
          | Scatter { context, sender + session token + service, deadline, outstanding targets,
                      parts / ok / failed, max_results, ordered delivery }

edges: Map<(sender service, type), Edge>          (dashboard; dropped when it is disabled)
  Edge { kind, last_seen, slots: up to 10 x { count, errors, latency sketch } }
```

Every registry and session operation takes a `ContextId`. The only context is `default`: the
owner deferred contexts indefinitely, the parameter keeps the door open.

Rules enforced on `Register`:

- The first message on a stream must be a `Register`; anything else closes the stream with
  `FAILED_PRECONDITION`.
- A type in `command_types` or `query_types` may be owned by one service only. If a second service
  registers a type another service already owns, the hub rejects the `Register` with
  `ALREADY_EXISTS` and closes the stream; this is a deployment error and must be loud.
- A type in `shared_query_types` may be owned by many services ([Query modes](protocol.md#query-modes),
  ADR 0017). Registrants must agree: a type
  registered exclusive by one registrant and shared by another (even of the same service) fails
  the later `Register` with `ALREADY_EXISTS`; a type listed as shared and as a command or
  exclusive query in one `Register` is `INVALID_ARGUMENT`. Commands are never shared.
- A `Register` with an empty `service_name` or `instance_id`, or with `initial_permits` 0, is
  rejected with `INVALID_ARGUMENT`.
- a type listed under both `command_types` and `query_types` in one `Register` is
  rejected with `INVALID_ARGUMENT`.
- registering a type under a different kind than its current owner uses is
  rejected with `ALREADY_EXISTS`. A type's kind cannot change while it is owned; change it only
  after every instance of the owner has left and the owner grace sweep has removed the type.
- A later `Register` on the same stream replaces that instance's type list. Its `client_version`,
  `initial_permits`, `load_factor` and `tags` are ignored: the first `Register` of a stream fixes
  them.
- Every accepted `Register` is answered with a `RegisterAck` ([Handshake](protocol.md#handshake)).
- `Register.credentials` is judged by [access control](configuration/index.md) (modes `permissive` and
  `enforce`) and ignored in mode `off`; it is read from the first `Register` of a
  stream only and never logged.
- With access control on, a `Register` is also refused with `UNAUTHENTICATED` (no or unknown
  credentials) or `PERMISSION_DENIED` (a service name or a handled type the token does not grant);
  see [Access control](configuration/index.md).
- A reconnecting instance that reuses its `instance_id` replaces the previous session; the hub logs
  the replacement.
- When the last instance of a service disconnects, its types stay in `types` for
  `SNODRA_SERVER_OWNER_GRACE` (default 60 s) so a restarting service does not race a different owner,
  then they are removed. Each owner of a shared type has its own grace; the type goes when its
  last owner's grace expires.

## Routing rules

| Kind | `routing_key` present | Target |
|---|---|---|
| COMMAND | yes | the instance returned by the owning service's weighted consistent-hash ring for the key; all requests with the same key for that service go to the same instance while membership is stable; affinity wins (a full queue rejects, never reroutes) |
| COMMAND | no | best tag match, then can take a request now, then least loaded, round-robin among ties (below) |
| QUERY | any | as an unkeyed command (the key is ignored); for a shared type, over every live instance of every owner (one pool, one rotation per type) |
| QUERY, mode `SCATTER_GATHER` | any | every live instance of every owner that lists the type ([Query modes](protocol.md#query-modes)) |
| QUERY, mode `STREAMING` | any | one instance, chosen as an unkeyed request among the live instances of the owner(s) that list the type ([Query modes](protocol.md#query-modes)) |

Choosing among the owning service's instances for unkeyed requests (ADR 0014):

1. the best tag-match score: the number of the sender's `Register.tags` pairs the instance has
   with the same value;
2. among those, instances that can take a request now (a permit and an empty queue), if any;
3. the least `(queued + forwarded) / load_factor`;
4. round-robin among the remaining ties (a rotation counter per service).

Consequences of these rules:

- The ring saturates the load factor (virtual nodes clamped to 8..1024, so above 800 a larger
  load factor no longer moves keys), while the least-loaded choice uses the raw value.
- At idle every load is 0, so unkeyed traffic round-robins whatever the load factors; the load
  factor only shifts traffic once instances are busy.
- Tags are a strict preference: an instance with the best match keeps receiving (and queueing)
  unkeyed requests when it is saturated; nothing spills over to a worse match.
- An instance registered without types (a sender only, or one stopping gracefully: its last
  `Register` is empty) is no routing target, neither a candidate nor on the ring.

> the ring gives an instance `128 x load_factor / 100` virtual nodes
> (`Register.load_factor`, 0 reads as 100, clamped to 8..1024), points `xxh64("<instance>#<i>")`
> and keys `xxh64(service_name + ":" + routing_key)`. A colliding point belongs to the smaller
> instance id, so the ring is the same on every hub whatever the registration order. Rebalancing
> on membership or load-factor change is the usual consistent-hash behaviour: only keys that mapped
> to the departed or added points move.

### Flow control

- Every session is flow-controlled: `Register.initial_permits` (at least 1; 0 is
  `INVALID_ARGUMENT`) are its first permits, and it is forwarded a request only while it has a
  permit (one per forward); `Permits{count}` adds permits, never beyond the session's cap. The cap
  starts at `initial_permits`; a `Permits.grant > 0` first raises it to `max(cap, grant)` (a grant
  never lowers it), which is how a multi-hub client moves a departed hub's share to this one (see
  the permit top-up below). Permits, load factor and tags come from the first `Register` of a
  stream.
- A stream opens its flow state before its session becomes current, so a request for the
  session always finds it; a request for a session without flow state (it ended or was
  replaced) fails with `HANDLER_DISCONNECTED` rather than being sent unmetered. Of two concurrent
  handshakes of one instance id the newer stream wins, in the sessions and the flow state alike.
- With a permit and nobody waiting the request is forwarded at once (no cap applies). Otherwise
  it waits in the instance's queue: `Request.priority` first (higher wins, default 0), then
  arrival, with its own deadline (`TIMEOUT`).
- A queued request never left the hub. When its instance disconnects it is routed again with the
  same id and its remaining deadline (keyed: the new ring owner; unkeyed: another candidate;
  none left: `NO_HANDLER`, which a command may retry). When the instance reconnects (a new stream
  replaces the old session) the new session takes the queue over. When the instance stops
  gracefully (empty `Register`) its queue is routed to the other instances at once. Only
  forwarded requests fail with `HANDLER_DISCONNECTED`.
- Bounds: `SNODRA_SERVER_QUEUE_CAPACITY_PER_INSTANCE` (10 000 requests),
  `SNODRA_SERVER_QUEUE_BYTES_PER_INSTANCE` (64 MiB, encoded size) and `SNODRA_SERVER_QUEUE_BYTES_TOTAL`
  (512 MiB over all queues of the hub). Beyond any of them, and when a session buffer is full, the
  sender gets `RESOURCE_EXHAUSTED` (`handler busy: <reason>`).

> routing granularity is per service. All live instances of the owning service
> are routing targets, on the assumption that every instance of a service handles the
> same types (homogeneity). During a mixed-version rollout a request may reach an instance that no
> longer handles the type; that instance's library answers `NO_HANDLER` and the sender sees a
> transient `NoHandlerException`.

Why hash commands: it lets a service keep per-aggregate in-memory state or locks safely when it runs
more than one instance, which is what the routing key provides. Queries have no such need.

Scatter-gather, streaming queries, subscription queries and shared query types: see
[Query modes](protocol.md#query-modes) and the client APIs in [Client APIs](protocol.md). A screen that
refreshes on change can use a subscription query; until an edge service exposes one the client polls or
uses TanStack Query refetching.

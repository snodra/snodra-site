# API

## Semantics worth knowing

- **Errors** map exactly as `HubErrors.kt`: `NoHandler`, `Timeout`, `HandlerDisconnected`,
  `RemoteHandler`, `Unauthenticated`, `AccessDenied`, `InvalidMessage`, `HubUnavailable`,
  `HubConnectionLost`, `HandlerBusy`. `HandlerBusy` (hub code `RESOURCE_EXHAUSTED`): the hub's
  queue or session buffer for the target instance is full; the handler never saw the request.
  `HubUnavailable`: the request was never written to a live hub stream (no
  stream, or the write failed), so a retry is safe. `HubConnectionLost`: the request was accepted by
  a stream's outbound queue and that stream broke before the answer, so the outcome is unknown (treat
  it like `Timeout`). An unknown code reads as `RemoteHandler`. A handler's
  `Err` becomes `HANDLER_ERROR` unless it is `Unauthenticated`/`AccessDenied`/`InvalidMessage`; a panic
  becomes `HANDLER_ERROR "handler panicked"`, never a dropped stream.
- **Guards** run before the payload is decoded: anonymous → `UNAUTHENTICATED`, refused → `PERMISSION_DENIED`.
- **Unit replies** travel as `{}`; an `Option::None` reply stays `null`.
- **Consumer** (one per [event processor](#event-processors)): one record at a time; marker
  inserted first (a duplicate id never reaches the handler), handlers run, commit, then the offset.
  A failing or panicking handler is retried `max_attempts` times with 1 s backoff (a payload the
  event type cannot be read from, `InvalidMessage`, is not retried), then the record becomes a
  [dead letter](dead-letters.md) before its offset is committed (mode `log`: logged, type, id,
  topic-partition@offset, never the payload, and skipped). Records with an unhandled type are
  skipped; records without `type`, or with a non-object payload for a handled type, are INVALID
  letters.
- **Outbox**: `publish` inserts; the publisher relays in `createdAt, seq` order, stops the batch on a
  retriable failure, marks `failedAt` after 10 attempts, or at once for non-retriable failures (oversized record, invalid or
  unauthorized topic). Delivery budget per attempt is 30 s, as in the Kotlin producer. `userId` header is `""` when anonymous.
- **Mongo documents** use the Kotlin field names and BSON types; no `_class` field is written.
- **Mongo access**: `builder.client()` / `app.client()` and `database()` expose the crate's client; sessions passed to
  `events.publish_in` must come from it (the driver rejects sessions of another client).
- **Verified identity** checks signature, `exp`, `nbf` and `iss`; `aud` is not validated (Keycloak sets it, Spring's
  decoder ignores it too). A JWKS outage is `UNAUTHENTICATED` for the caller, never an internal error with a URL.
- **Shutdown** drains in-flight handlers (10 s bound), closes every hub stream, fails this instance's outgoing requests still in flight with `HubConnectionLost`, stops the publisher and the consumer.
- **Start** does not wait for the hub. `await_hub(timeout)` tells you when the registration was
  confirmed by at least one hub (requests can then be sent; before that they fail with
  `HubUnavailable`); `await_all_hubs(timeout)` waits until every hub confirmed it (with
  `dns:///`: every address of the latest resolution; a second target of a hub already reached does
  not count). `app.hub_ids()` lists the hubs registered on now. snodra-messaging (Kotlin) differs
  here: its `HubConnections.awaitRegistered` waits for every hub, like `await_all_hubs`.
- **Handshake**: `Register` carries `client_version = snodra-messaging-rs/<version>`. The hub answers
  every `Register` with a `RegisterAck` (before it echoes the heartbeat that follows), which
  completes the handshake: the client then heartbeats at the announced interval (3 s; the hub
  evicts after 10 s; 3 s before the ack too) and sends `timeout_ms = 0` unless a timeout was
  chosen, guarding locally with the ack's per-type or maximum timeout plus 1 s. A stream without an
  ack within 10 s (`HubSettings.handshake_timeout`) is abandoned and opened again with the normal
  backoff; a heartbeat echo confirms nothing. `HubConnection::handshake()` returns the ack. The
  hub and this library ship together: a hub of another commit is not supported.
- **Flow control** (ADR 0014): `Register` offers `max_concurrent_handlers` permits, `load_factor`
  and `tags`. The hub forwards only while this instance has permits and queues the rest (by
  priority, then age; queued requests keep their own deadline). Every finished request gives its permit back on
  the stream it arrived on. The hub still holds `initial − received + returned` of this stream's
  permits (offered, minus requests that arrived, plus permits written back); once that is at or
  below the low-water mark `min(16, initial / 2)` the pending grants go back at once (with one
  permit, every completion does), otherwise they are batched: one `Permits` message at 16 pending
  grants or 50 ms after the first unsent one. Requests that arrive before the ack follow the same
  rule.
- **SendOptions**: `routing_key`, `timeout`, `authorization`, `priority` (else
  `SNODRA_SERVER_PRIORITIES` for the type, else 0) and `retry` (else `Config.hub_retry`, from
  `SNODRA_SERVER_RETRY_*`). A `RetryPolicy` is in force as written: `RetryPolicy::default()` is 3
  attempts, 100 ms doubling to 2 s; `Some(RetryPolicy::NONE)` (one attempt) switches a configured
  policy off for one call. A policy with `max_attempts: 0` fails the call with `InvalidMessage`
  before anything is sent (`Config::validate` rejects it at startup).
- **Retry** (opt-in: no policy applies unless `Config.hub_retry` or `SendOptions.retry` sets
  one): `retry::is_retryable(kind, &error)` is the one classification (shared with
  the saga relay). Commands retry `HubUnavailable`, `NoHandler` and `HandlerBusy` (the handler never
  ran); queries also `HandlerDisconnected`, `Timeout` and `HubConnectionLost`. A command whose
  outcome is unknown is never retried; nothing else is retried. Each attempt has a fresh request id.
  All attempts share one budget: the caller's timeout, else the hub's bound for the type (override,
  else default; 5 s while no hub has acknowledged this instance yet). A retry starts only if, once its backoff is over, at
  least `max(initial_backoff, 250 ms)` of the budget is left; otherwise the last error is returned
  at once, without waiting. Each attempt sends what is left of the budget as `timeout_ms`, never
  less than 1 ms (a remainder never turns into "unset", which would let the hub apply its default).
- **Liveness**: a stream with no heartbeat echo for three intervals is dropped and reconnected; the
  channel also sends HTTP/2 keepalive pings every 10 s (5 s to answer, also while idle).
- **Replies** go back on the stream the request arrived on; when that stream is gone the reply is
  dropped, never sent on a newer one. The hub has already failed the request with
  `HANDLER_DISCONNECTED`, including when this instance reconnected with the same instance id while
  the old stream was still registered.

## Multiple hubs

High availability without hub-to-hub traffic (ADR 0016):
every instance registers on every hub, and the client picks a hub per request.

- **Targets.** `SNODRA_SERVER_ADDRESS=static://hub:7000,hub-2:7000` lists the hubs (blanks and
  repeats of the same target are ignored). `SNODRA_SERVER_ADDRESS=dns:///snodra-server:7000` connects to
  every address the name resolves to, as `ip:port`, of one family only: the IPv4 addresses when
  there is any, else the IPv6 ones (a dual-stack name lists each hub twice, and two streams of one
  instance on one hub replace each other). It is resolved at start and every 30 s: a new address gets a
  connection, a vanished one leaves the routing at once and gets an empty `Register` (that hub
  stops routing to this instance and hands its queue to other instances; replies to requests it
  already forwarded still go through), and is closed once idle (no request of ours written to it
  unanswered, no handler of its requests running; at most 65 s later). A
  failed or empty resolution keeps the current hubs. `dns:///` must be the only target and needs a
  port; its host may not contain `/`; `dns://server/...` is not supported. An address that names no hub fails `Config::validate`.
- **Connections.** One stream per hub, each with its own handshake, heartbeat and reconnect
  backoff, all with the identical `Register`. Two targets whose acks carry the same
  `hub_id` are one hub: the connection acknowledged first keeps it and the other is closed for
  good (logged once). The hub replaces a session when the same instance registers again, so the
  kept connection reconnects once, and the hub drops the instance until it is back (well under a
  second with the default backoff). A hub whose ack carries an empty `hub_id` (a real hub always
  names itself) is known by its target as `host:port`, the `static://` or `http(s)://` prefix stripped
  (`hub::target_id`, the same rule as snodra-messaging); a resolved address is `ip:port`.
- **Routing.** An unkeyed request goes round-robin over the hubs whose stream is acknowledged
  (reconnecting hubs are skipped). A request with a `routing_key` goes to the live hub with the
  highest rendezvous score, so a key keeps its hub while the hubs are stable and only the keys of a
  hub that leaves move (every hub's ring then picks the same instance):

  ```text
  score(hub_id, key) = fmix64(fnv1a64(utf8(hub_id) ++ [0x00] ++ utf8(key)))
  fnv1a64: h = 0xcbf29ce484222325; for each byte b: h = (h ^ b) * 0x100000001b3   (wrapping)
  fmix64:  k ^= k >> 33; k *= 0xff51afd7ed558ccd; k ^= k >> 33; k *= 0xc4ceb9fe1a85ec53; k ^= k >> 33
  ```

  `hub::rendezvous_score` implements it; test vectors: `("", "")` → `0xb9034ad37056f5fb`,
  `("hub-1", "order-42")` → `0x5c855509f5ad7c8d`, `("hub-2", "order-42")` → `0xd109ca177e04ae14`.
  The finalizer is there because plain FNV-1a sent 80 % of the keys `order-0` … `order-999` to one
  of three hubs.
- **Failover.** A request that could not be written to its hub's stream (the stream dropped
  before the client noticed) goes to the next hub in the same order with the same request id: it
  was never sent. So does one still waiting in the stream's outbound buffer (up to 256 messages)
  when the stream drops: the transport never took it, so it was never written (as in
  snodra-messaging). `HubUnavailable` means no hub took it. A request the transport had already
  taken fails with `HubConnectionLost` when its stream drops (outcome unknown: it may be on the
  wire); the retry policy then decides (queries are retried, commands are not). Replies go on the stream the request arrived on.
- **`NO_HANDLER` failover.** A unary send (a command or a point query; not a scatter-gather,
  stream or subscription) that a hub answers with `NO_HANDLER` was never delivered, so the other
  live, acknowledged hubs get it in turn, each at most once and within the caller's remaining
  timeout; if all decline, the last `NO_HANDLER` comes back at once, with no extra delay. A keyed
  command moves too (its preferred hub has no handler, so affinity cannot be kept anyway), in
  rendezvous order. This is what keeps a single owner instance reachable while it is deregistered on
  one hub, e.g. during a [client certificate rotation](configuration.md#authenticating-with-a-client-certificate-mtls)
  of the owner. It does not depend on the opt-in retry policy, which may still retry `NoHandler`
  afterwards by its own rules.
- **Permits.** A stream offers `ceil(max_concurrent_handlers / N)` permits, N being the hubs live
  when its `Register` is written, itself included (a hub still on its first connect attempt counts
  as live, so hubs that start together split from the start). When N shrinks from N_old to N_new
  (a hub is lost, its first attempt fails, it is closed as a duplicate or leaves DNS), every live
  stream gets one `Permits` top-up so that it holds `ceil(max / N_new)` in all: with 8 permits and
  two hubs each offers 4, and when one stops the survivor gets `Permits{count: 4, grant: 8}`; the
  grant raises the hub's permit cap on the session (otherwise its `initial_permits`) so the hub
  keeps the top-up. A stream that already
  offered that many (it was topped up before, or opened while another hub was down) gets nothing,
  so flapping hubs never inflate the permits. A joining or returning hub offers `ceil(max / N)`
  afresh. Permits are never revoked when N grows; the local concurrency limit stays
  `max_concurrent_handlers` over all hubs, so a hub may briefly hold more permits than this
  instance runs at once, and the extra requests wait locally (same rule as snodra-messaging).
- **Status.** Every `SNODRA_SERVER_STATUS_INTERVAL_MS` the instance sends `InstanceStatus` to every
  hub: `connected_hub_ids` (the acknowledged hubs), `handlers_in_flight` (handlers running over all
  hubs) and the [event processors](#event-processors)' status. Each hub shows the report in its topology
  (`connectedHubIds`, `statusAgeMs`) and its dashboard flags instances missing a hub.
- **Logs** of each connection carry its `address` (and the `hub` id once acknowledged). The crate
  has no metrics of its own.

## Scatter-gather

Shared query types and scatter-gather queries (ADR 0017),
the counterpart of snodra-messaging's `scatterGather` and `@QueryHandler(shared = true)`.

```rust
use snodra_messaging::hub::{ScatterOptions, ScatterPart, ScatterResult};

// Handler side: several services may own Search. A per-target request has the id `<id>#<n>`
// and is served like any query.
let app = SnodraMessaging::builder(config).await?
    .shared_query::<Search, _, _>(|q, ctx| async move { Ok(Hits { .. }) })
    .start().await?;

// Sender side: every live instance of every owner answers.
let result: ScatterResult<Hits> = app.queries().scatter_gather(&Search { term }, ScatterOptions {
    timeout: Some(Duration::from_secs(2)), // the whole gather; else Config.hub_request_timeout, else the hub's
    max_results: 0,                        // end after this many successful parts (0: all targets)
    priority: None,                        // else SNODRA_SERVER_PRIORITIES for the type, else 0
}).await?;
for ScatterPart { service, instance, outcome } in result.parts { /* arrival order */ }
let (failed, timed_out) = (result.failed, result.timed_out);

// Or part by part, completing on the hub's ReplyEnd:
let mut parts = app.queries().scatter_gather_stream(&Search { term }, ScatterOptions::default());
while let Some(part) = parts.next().await { let part = part?; /* ... */ }
```

| API | Signature |
|---|---|
| Register a shared query | `SnodraMessagingBuilder::shared_query::<Q, F, Fut>(handler) -> Self` (also `HandlerRegistry::shared_query`) |
| Registered types | `HandlerRegistry::query_types()` (every query, exclusive and shared), `exclusive_query_types()`, `shared_query_types()`; `registered_types() -> RegisteredTypes { commands, queries (exclusive), shared_queries }` is what the `Register` announces |
| Gather | `Sender::scatter_gather<Q: Query>(&self, &Q, ScatterOptions) -> Result<ScatterResult<Q::Reply>, MessagingError>` |
| Stream | `Sender::scatter_gather_stream<Q: Query>(&self, &Q, ScatterOptions) -> impl Stream<Item = Result<ScatterPart<Q::Reply>, MessagingError>>` |
| Options | `ScatterOptions { timeout: Option<Duration>, max_results: u32, priority: Option<i32> }` (`Default`) |
| Result | `ScatterResult<R> { parts: Vec<ScatterPart<R>>, failed: u32, timed_out: u32 }` |
| Part | `ScatterPart<R> { service: String, instance: String, outcome: Result<R, RemoteError> }` |
| Part failure | `RemoteError { code: ErrorCode, message: String, details: Vec<u8> }`, `into_error(type)` gives the unary error |

- **Shared registration.** `shared_query` puts the type in `Register.shared_query_types` instead
  of `query_types`. Registering one type both as `query` and `shared_query` panics at startup.
  Exclusive vs shared must be consistent across **every** registrant of the type, in every
  service: the hub answers `ALREADY_EXISTS` at register time to the one that disagrees (the
  connection keeps retrying at the backoff cap, `last_rejection` says why). Switching a type
  between the two needs every registrant gone and the owner grace expired. Commands are never
  shared.
- **Point queries still work.** `send_query` on a shared type goes to one live instance of any
  owner (one round-robin pool over all owners at the hub).
- **Answers.** One part per target answer, in arrival order; a failed target is a part whose
  `outcome` is a `RemoteError` (the handler's error, or `HANDLER_DISCONNECTED`,
  `RESOURCE_EXHAUSTED` from the hub); a reply that does not decode is a failed part with code
  `UNSPECIFIED`. `failed` counts the failed parts, `timed_out` the targets without an answer at
  the deadline. Partial answers are answers: the call succeeds; check `failed + timed_out` for
  "all or error". Payloads use the unary reply codec (`()` accepts `{}`).
- **Errors before any target** are the unary ones: no live target `NoHandler`, a command type
  `InvalidMessage`.
- **Transport.** One gather goes to one hub (unkeyed round-robin). If its
  stream breaks before the end, the gather fails with `HubConnectionLost` (the parts received are
  dropped, none is retried on its own); one never written moves to the next hub like a unary
  request. The local guard (the hub's bound plus 1 s) covers the whole gather (`Timeout`).
  Parts and ends of unknown requests are ignored, and dropping the stream abandons the gather.
- **Retry.** `Config.hub_retry` applies to the whole gather for the same errors as a unary query
  (`HubUnavailable`, `NoHandler`, `HandlerBusy`, `HandlerDisconnected`, `Timeout`,
  `HubConnectionLost`): a retry is a new gather with a fresh id, collected from scratch, within the
  same budget. The stream retries only until its first part; after that an error ends it.

## Streaming queries

A query whose result is a flow of items from one instance of one owner, under the caller's
back-pressure (ADR 0017),
the counterpart of snodra-messaging's streaming query API.

```rust
use futures::StreamExt;
use snodra_messaging::{StreamOptions, StreamingQuery};

#[derive(serde::Serialize, serde::Deserialize)]
struct Export { since: chrono::DateTime<chrono::Utc> }
#[derive(serde::Serialize, serde::Deserialize)]
struct Row { id: String }
message_type!(Export, "files.Export");
impl StreamingQuery for Export { type Item = Row; }

// Handler side: return any `Stream<Item = Result<Row, MessagingError>>`; it is pulled at most
// one item ahead of the sender's credit. An `Err` item ends the stream with that error.
let app = SnodraMessaging::builder(config).await?
    .streaming_query::<Export, _, _, _>(|q, ctx| async move { Ok(rows_since(q.since)) })
    // .shared_streaming_query::<Search, _, _, _>(..)   // many services may own it
    .start().await?;

// Sender side: the open waits for the first item (or the end, or a failure); then pull.
let mut rows = app.queries().stream(&Export { since }, StreamOptions {
    timeout: None,         // idle timeout (hub-side, reset by every part); else Config.hub_request_timeout, else the hub's
    max_results: 0,        // end after this many items (the hub cancels the handler); 0: no limit
    priority: None,        // else SNODRA_SERVER_PRIORITIES for the type, else 0
    initial_credit: 64,    // the credit window; half of it is refilled every time half was consumed
}).await?;
while let Some(row) = rows.next().await { let row = row?; /* in the handler's order */ }

// `stream` borrows the sender: its stream cannot leave the scope of `app.queries()`. For an
// HTTP streaming body or a spawned task, `stream_owned` on the shared sender is `'static`.
let rows = app.sender().stream_owned(&Export { since }, StreamOptions::default()).await?;
tokio::spawn(async move { rows.try_for_each(|row| async { Ok(()) }).await });
```

| API | Signature |
|---|---|
| Trait | `trait StreamingQuery: MessageType + Serialize + DeserializeOwned + Send + Sync + 'static { type Item: Serialize + DeserializeOwned + Send + 'static; }` |
| Register a handler | `SnodraMessagingBuilder::streaming_query::<Q, F, Fut, S>(handler) -> Self` and `shared_streaming_query` (also on `HandlerRegistry`), with `F: Fn(Q, MessageContext) -> Fut`, `Fut: Future<Output = Result<S, MessagingError>>`, `S: Stream<Item = Result<Q::Item, MessagingError>> + Send + 'static` (a `BoxStream` fits) |
| Registered types | `HandlerRegistry::streaming_query_types()` (exclusive and shared); `registered_types() -> RegisteredTypes { commands, queries, shared_queries, streaming_queries }`: `streaming_queries` are the exclusive streaming types, announced in `Register.query_types` with `queries`; a shared streaming type is in `shared_queries` like any shared query (the hub does not tell a streaming type from a unary one: the mode is the sender's choice) |
| Stream | `Sender::stream<Q: StreamingQuery>(&self, &Q, StreamOptions) -> Result<BoxStream<'_, Result<Q::Item, MessagingError>>, MessagingError>` (`async`): the stream borrows the sender |
| Owned stream | `Sender::stream_owned<Q: StreamingQuery>(self: &Arc<Self>, &Q, StreamOptions) -> Result<BoxStream<'static, Result<Q::Item, MessagingError>>, MessagingError>` (`async`): the stream holds a clone of the `Arc<Sender>`, so it can be returned or moved into a task; `SnodraMessaging::sender()` (and the builder's `sender()`) is that `Arc`. Same behaviour otherwise |
| Options | `StreamOptions { timeout: Option<Duration>, max_results: u32, priority: Option<i32>, initial_credit: u32 }` (`Default`: `initial_credit` 64, `hub::DEFAULT_CREDIT`; 0 reads as 64) |
| Errors | `MessagingError::NoHandler`, `InvalidMessage`, `Timeout`, `RemoteHandler`, `HandlerDisconnected`, `HandlerBusy`, `Cancelled` (the hub's max stream duration), `HubUnavailable`, `HubConnectionLost`, `Serialization` |

- **One handler, one instance.** A stream goes to one hub (unkeyed round-robin), which picks one
  instance listing the type as for a point query (on a
  shared type, one pool over every owner). The handler gets `Request{id = <id>#1, mode =
  STREAMING, initial_credit}` and only a streaming handler serves it. A type has one handler,
  whatever its kind, and the mode must match it: a stream to a type whose handler is unary ends
  with `INVALID_REQUEST` ("`<type>` is not a streaming query handler (it answers mode UNARY)"),
  a unary query to a streaming type is answered `INVALID_REQUEST` ("`<type>` is a streaming
  query: send it with Sender::stream (mode STREAMING)"): the caller used the wrong mode, which no
  retry fixes (`InvalidMessage`, never retried), unlike `NoHandler` for a type the instance does
  not serve at all.
- **Credits.** The handler's stream is pulled at most one item ahead of the credit
  (`initial_credit` plus every `Flow`): an item is held until there is credit to send it, one
  `ReplyPart` per item (`seq` from 1); its end (or failure) is sent as `ReplyEnd` as soon as the
  stream reports it, with or without credit, so a sender that grants exactly as many credits as
  there are items gets the end. The sender refills `max(1, initial_credit / 2)` credits every
  time that many items were pulled by the caller (not on arrival), so a handler never runs more
  than a window (plus the held item) ahead of the consumer. Items use the unary reply codec
  (`()` accepts `{}`).
- **Borrow or share.** `stream` returns `BoxStream<'a>` borrowing the `&'a Sender`: the stream
  lives inside that borrow, so it cannot be returned from a handler that only borrowed the app
  (an HTTP streaming body) or moved into `tokio::spawn`. `stream_owned` takes `&Arc<Sender>` and
  returns `BoxStream<'static>` holding a clone of it: the sender outlives the stream, and the
  drop guard (`Cancel` on drop before the end) works the same.
- **Open.** `stream().await` returns once the first item is in (or the end: an empty stream), so
  everything before that is the call's error: `NoHandler` (no owner), `InvalidMessage` (a
  command type), `Timeout` (no first item within the idle timeout), the
  handler's error (`RemoteHandler`, ...), `HubUnavailable` / `HubConnectionLost`.
- **Endings.** The stream ends on the hub's `ReplyEnd`; with an error it is the last item, mapped
  like a unary error of that code: `Timeout` (the idle timeout, from the forward and reset by every
  part), `RemoteHandler` (the handler's `Err` item, or a part beyond the credit: `InvalidMessage`),
  `HandlerDisconnected` (the handler left), `Cancelled` (`SNODRA_SERVER_MAX_STREAM_DURATION`). A hub
  stream lost after the first item is `HubConnectionLost`, a part that does not decode
  `Serialization` (the handler is cancelled). The sender checks for lost parts (the hub drops a
  part it could not buffer within 5 s): `seq` must run 1, 2, 3, ... in arrival order and a clean
  `ReplyEnd.parts` must equal the parts that arrived; otherwise the last item is
  `InvalidMessage` "stream `<type>` lost N part(s)" (at a gap the handler is cancelled, reason
  `lost parts`; a part out of order is `InvalidMessage` too). After `max_results` items the hub ends the stream
  and cancels the handler. The local guard (for a hub that never answers; it cancels the stream,
  best effort) allows 2 x the hub's bound plus 1 s for the first part (the hub bounds a queue
  wait by the timeout and then restarts the idle clock at the forward) and the bound plus 1 s,
  reset by every part, after it.
- **Cancel.** Dropping the stream before its end sends `Cancel{id, "dropped by the sender"}`
  (best effort, from the drop) and forgets the request, also when the open is dropped while its
  write is still blocked. A handler whose stream is cancelled by the hub (the sender dropped it or
  left, `max_results`, the idle timeout, the hub's limits) has its stream dropped and sends
  nothing more; the hub's `Cancel` for a unary or scatter-gather target (a gather that ended
  early) aborts that handler too (a handler whose work must finish once started, say a write
  followed by a publish outside one transaction, should `tokio::spawn` that section and await the
  join handle: the spawned task is not aborted with the handler). When the hub stream a streaming request arrived on is lost,
  its handler is aborted as well (the hub forgot the stream with the session; it would wait for
  credit for ever), while a unary handler runs on with its reply dropped. A handler
  that waits for credit longer than `Config.hub_stream_credit_timeout`
  (`SNODRA_SERVER_STREAM_CREDIT_TIMEOUT_MS`, 10 min: the hub's default maximum stream duration)
  ends its stream with `ReplyEnd{error = TIMEOUT "no credit within <d>"}`: a hub that forgot the
  stream (a race, a lost `Flow` or `Cancel`) cannot leak the handler task. The handler
  permit (`max_concurrent_handlers`, and the hub's) is held for the whole stream and released on
  every ending path.
- **Retry.** `Config.hub_retry` applies until the first item, for the same errors as a unary query
  (`HubUnavailable`, `NoHandler`, `HandlerBusy`, `HandlerDisconnected`, `Timeout`,
  `HubConnectionLost`): a retry is a new stream with a fresh id; a hub stream lost while the
  request still sat in its outbound buffer moves to the next hub with the same id, as a unary
  request. Every attempt sends the chosen idle timeout as is (it is an idle timeout, not a
  deadline: unlike a unary retry, an attempt does not send what is left of the budget); the
  budget only bounds how many attempts there are. Nothing is retried after the first item.

## Subscription queries

A query whose result is an initial value followed by the updates every owner instance pushes,
until the subscriber cancels or the owners complete (ADR 0017),
the counterpart of snodra-messaging's subscription query API.

```rust
use futures::StreamExt;
use snodra_messaging::{SubscriptionOptions, SubscriptionQuery};

#[derive(serde::Serialize, serde::Deserialize)]
struct Prices { symbol: String }
#[derive(serde::Serialize, serde::Deserialize)]
struct Quote { symbol: String, price: u32 }
#[derive(serde::Serialize, serde::Deserialize)]
struct Tick { symbol: String, price: u32 }
message_type!(Prices, "market.Prices");
impl SubscriptionQuery for Prices { type Initial = Quote; type Update = Tick; }

// Handler side: the handler answers the initial result; the updates are pushed through the
// emitter by whatever changes the data. Capture the emitter before `start()`.
let builder = SnodraMessaging::builder(config).await?;
let emitter = builder.emitter();
let app = builder
    .subscription_query::<Prices, _, _>(|q, ctx| async move { Ok(latest_quote(&q.symbol).await?) })
    // .shared_subscription_query::<Prices, _, _>(..)   // many services may own it
    .start().await?;

// ... wherever the data changes (after the commit of the write that changed it):
emitter.emit::<Prices>(|q| q.symbol == "ACME", &Tick { symbol: "ACME".into(), price: 101 });
emitter.complete::<Prices>(|q| q.symbol == "ACME");                       // a clean end
emitter.complete_exceptionally::<Prices>(|_| true, &MessagingError::Storage("feed down".into()));

// Sender side: `subscribe` returns once the initial result is in.
let sub = app.sender().subscribe(&Prices { symbol: "ACME".into() }, SubscriptionOptions {
    timeout: None,        // the initial result's timeout (queue wait + handler); else Config.hub_request_timeout, else the hub's
    max_results: 0,       // end after this many updates (the initial result does not count); 0: no limit
    priority: None,       // the initial request's; else SNODRA_SERVER_PRIORITIES for the type, else 0
    initial_credit: 64,   // the credit window; half of it is refilled every time half was consumed
}).await?;
println!("{}", sub.initial.price);
let mut updates = sub.updates;                      // hot: fed by the hub from the open on
while let Some(update) = updates.next().await { let tick = update?; /* in the hub's arrival order */ }
// `sub.cancel()` (or dropping the subscription, or just its `updates`) cancels it at the hub.
```

| API | Signature |
|---|---|
| Trait | `trait SubscriptionQuery: MessageType + Serialize + DeserializeOwned + Send + Sync + 'static { type Initial: Serialize + DeserializeOwned + Send + 'static; type Update: Serialize + DeserializeOwned + Send + 'static; }` |
| Register a handler | `SnodraMessagingBuilder::subscription_query::<Q, F, Fut>(handler) -> Self` and `shared_subscription_query` (also on `HandlerRegistry`), with `F: Fn(Q, MessageContext) -> Fut`, `Fut: Future<Output = Result<Q::Initial, MessagingError>>`: the handler answers the initial result |
| Registered types | `HandlerRegistry::subscription_query_types()` (exclusive and shared); `registered_types()` has `subscription_queries`, the exclusive ones, announced in `Register.query_types` with `queries`; a shared subscription type is in `shared_queries` like any shared query |
| Emitter | `QueryUpdateEmitter` (`Clone`): `emit<Q: SubscriptionQuery>(&self, filter: impl Fn(&Q) -> bool, update: &Q::Update)`, `complete<Q>(&self, filter)`, `complete_exceptionally<Q>(&self, filter, error: &MessagingError)`. From `SnodraMessagingBuilder::emitter()` (to capture in handlers and in the code that changes the data) or `SnodraMessaging::emitter()`; also `open_subscriptions()` |
| Subscribe | `Sender::subscribe<Q: SubscriptionQuery>(self: &Arc<Self>, &Q, SubscriptionOptions) -> Result<Subscription<Q>, MessagingError>` (`async`): owned, like `stream_owned` (`app.sender()` is the `Arc`); there is no borrowed variant |
| Result | `Subscription<Q> { initial: Q::Initial, updates: BoxStream<'static, Result<Q::Update, MessagingError>> }` with `cancel(self)` |
| Options | `SubscriptionOptions { timeout: Option<Duration>, max_results: u32, priority: Option<i32>, initial_credit: u32 }` (`Default`: `initial_credit` 64, `hub::DEFAULT_CREDIT`; 0 reads as 64; retry: `Config.hub_retry`) |
| Handler limit | `Config.hub_max_subscriptions` (`SNODRA_SERVER_MAX_SUBSCRIPTIONS`, 1024; `Dispatcher::max_subscriptions` when wired by hand) |
| Errors | `MessagingError::NoHandler`, `InvalidMessage`, `Timeout`, `RemoteHandler`, `HandlerDisconnected`, `HandlerBusy`, `Cancelled` (the hub's max duration), `HubUnavailable`, `HubConnectionLost`, `Serialization` |

- **Who is asked.** A subscription goes to one hub (unkeyed round-robin), which asks every live
  instance of every owner (exclusive or shared type) that lists the type, **as they are at the
  open**: an instance
  registering later is not added and one that leaves is not replaced. Updates are delivered
  **at most once** and neither the hub nor this library resubscribes: after a rolling restart a
  subscription listens to fewer instances than serve the type (an update emitted on a new
  instance is lost), and the subscriber only learns of it when the last instance left
  (`HandlerDisconnected`). A subscriber that needs every instance subscribes again.
- **Initial result and updates.** One of these instances, chosen as for a point query, also gets
  `Request{id = <id>#0, mode = UNARY}`: the registered handler answers it like a unary query
  (it holds a handler permit and is bounded by the timeout). Every one of them gets
  `Request{id = <id>#n, mode = SUBSCRIPTION}`, which registers a subscription on it (the decoded
  query, the request id and the arrival stream; no handler runs, no permit is held here or at
  the hub). It is registered as soon as the request is read, before its identity and guard are
  checked: a hub `Cancel` or a lost stream right behind it removes it (nothing is sent), updates
  emitted meanwhile are held and delivered, in order, once it is admitted (dropped when it is
  refused). The sender gets the initial result as `ReplyPart{seq = 1}` and then the updates as
  `ReplyPart{seq = 2, 3, ...}` in the hub's arrival order (the hub renumbers: per-source order
  is kept, there is no order between sources). A unary query to a subscription type (an id
  without the `#0` suffix) is answered `INVALID_REQUEST` ("`<type>` is a subscription query:
  send it with Sender::subscribe"), a subscription request to a type whose handler is unary or
  streaming ends with `INVALID_REQUEST` ("`<type>` is not a subscription query handler (it
  answers mode ...)"): the caller used the wrong mode, which no retry fixes.
  The initial request is recognised by the `#0` suffix of its id alone, which collides with
  scatter-gather (its targets are numbered from `#0` too): a gather of a subscription type sent
  by a raw client would have its target `<id>#0` answered with the initial result. Only raw
  clients can hit it, because the typed APIs never gather a subscription type.
- **Emitting.** `emit` sends one `ReplyPart` (the update serialized with the crate's codec,
  `seq` from 1 per subscription) to every open subscription of `Q` on this instance whose query
  passes the filter, in call order; `complete` a clean `ReplyEnd` and removes it;
  `complete_exceptionally` a `ReplyEnd{HANDLER_ERROR, message}` and removes it. No matching
  subscription: a no-op. A call never waits for the hub stream (one task per subscription
  writes in order). A clean end removes the instance silently at the hub; the last instance's
  clean end completes the subscription for the subscriber. An error end from any instance ends
  the whole subscription with that error (`RemoteHandler`) and cancels the others.
  **There are no transactions to defer to here** (the Kotlin library emits after the commit of
  the surrounding Spring transaction automatically): a handler that writes in a Mongo
  transaction must emit after its commit, or subscribers see an update of a write that may roll
  back.
- **Credits and the hub's buffer.** The credit is `initial_credit` plus every `Flow`; the
  initial result takes one, every update one. Updates beyond it wait at the hub, up to
  `SNODRA_SERVER_SUBSCRIPTION_BUFFER` (256) per subscription; one more ends the subscription with
  `ReplyEnd{RESOURCE_EXHAUSTED}`, which `updates` yields as its last item `HandlerBusy` (the
  hub's message, "subscriber buffer (256) exceeded", is logged at debug: the variant carries
  the type). Nothing is relayed to the owners: updates are pushed, and a consumer that falls
  further behind than the buffer resubscribes and gets a fresh initial result. The sender
  refills `max(1, initial_credit / 2)` credits every time that many parts were consumed; the
  initial result counts as consumed (it took a credit, so a window of 1 does not stall).
- **Open.** `subscribe().await` returns once the initial result is in, so everything before
  that is the call's error: `NoHandler` (no owner), `InvalidMessage` (a command type, or a
  handler of another mode), `Timeout` (no initial result within the
  timeout), the handler's error (`RemoteHandler`, ...), `HandlerBusy` (an instance at its
  subscription limit or a full queue), `HubUnavailable` / `HubConnectionLost`. An owner instance
  at its limit refuses its subscription with `ReplyEnd{RESOURCE_EXHAUSTED}` and the hub ends the
  whole subscription with it (the error is the call's, or comes right after the initial
  result). The hub itself refuses a subscription whose target already serves
  `SNODRA_SERVER_MAX_SUBSCRIPTIONS_PER_INSTANCE` (1024), before anything is sent.
- **Endings.** `updates` ends when the last owner instance completed cleanly or `max_results`
  updates were relayed (the hub then cancels the owners); an error is its last item, mapped like
  a unary error of that code: `RemoteHandler` (an owner's `complete_exceptionally`),
  `HandlerDisconnected` (the last owner left), `HandlerBusy` (the buffer), `Cancelled`
  (`SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION`, off by default), `HubConnectionLost` (the hub stream
  was lost), `Serialization` (an update that does not decode; the subscription is cancelled).
  There is no idle timeout and no local guard on updates: a quiet subscription is not a broken
  one. The only local guard is on the initial result (the hub's bound plus 1 s, as for a
  unary request).
- **Lost parts.** As for a stream, `seq` must run 1, 2, 3, ... in arrival order and a clean
  `ReplyEnd.parts` must equal the parts that arrived (the hub's count includes the initial
  result); otherwise the last item is `InvalidMessage` "subscription `<type>` lost N part(s)" and
  the subscription is cancelled at the hub (reason `lost parts`).
- **Cancel.** `Subscription::cancel`, dropping the `Subscription` or dropping its `updates`
  before the end sends `Cancel{id, "dropped by the sender"}` (best effort, from the drop) and
  forgets the request: the hub cancels every owner instance, which removes the subscription.
  The owners also drop a subscription on a hub `Cancel` (the subscriber left, `max_results`, the
  buffer, the hub's limits) and every subscription that arrived on a hub stream that was lost
  (the hub forgot it with the session). A shutdown (`SnodraMessaging::shutdown`) completes the
  subscriptions served here with a clean `ReplyEnd`, best effort and bounded to 2 s.
- **Retry.** `Config.hub_retry` applies until the initial result, for the same errors as a unary
  query (`HubUnavailable`, `NoHandler`, `HandlerBusy`, `HandlerDisconnected`, `Timeout`,
  `HubConnectionLost`): a retry is a new subscription with a fresh id; the timeout bounds the
  initial request like a unary one, so each attempt sends what is left of the call's budget. A
  hub stream lost while the request still sat in its outbound buffer moves to the next hub with
  the same id. Nothing is retried once the initial result is in.
- **Limits.** `Config.hub_max_subscriptions` bounds the subscriptions one instance serves (a
  subscription holds no permit: `max_concurrent_handlers` does not apply to it); beyond it a new
  request is refused with `ReplyEnd{RESOURCE_EXHAUSTED}` `subscription limit (N) reached`. The
  hub's buffer, per-instance limit and maximum duration are its own settings.

## Event processors

Each **event processor** is its own Kafka consumer on the events topic, with its own consumer
group, position, markers, dead letters and failure domain (ADR 0022; Axon's processing groups, the
Kotlin starter's `@ProcessingGroup`). A slow or failing handler in one processor never holds
another.

```rust,ignore
let app = SnodraMessaging::builder(config).await?
    .event::<OrderPlaced, _, _>(|e, ctx| async move { /* default */ Ok(()) })
    .event_in::<OrderPlaced, _, _>("projections", |e, ctx| async move { /* its own consumer */ Ok(()) })
    .event_in::<OrderShipped, _, _>("projections", |e, ctx| async move { Ok(()) })
    .start()
    .await?;
```

| Processor | Registered with | Consumer group | Markers in `processed_events` | Sagas |
|---|---|---|---|---|
| `default` | `event`, `idempotent_event` | `<service>.default` | `processor:default:<eventId>` | yes |
| `<name>` | `event_in(name, ..)` | `<service>.<name>` | `processor:<name>:<eventId>` | no (stage 1 only) |

- **Names** match `^[a-z0-9][a-z0-9-]{0,47}$` and are not `default`; a violation fails `start()`
  naming the handler (`event handler for <type>: processor name ...`).
- **One event type in several processors**: each gets every record and handles it in its own
  transaction with its own marker; a failure in one does not touch the other.
- **A processor starts only when it has handlers** (`default` also when only sagas run there) and
  `SNODRA_CONSUMER_ENABLED` is not `false`. Attempts and back-off are the shared consumer settings.
- **Other entry points** (partner topics, the webhook ingress, the relay's `SagaCommandFailed`
  notices) dispatch locally to every processor's handlers, each in its own transaction and marker
  family, and to the sagas once; they are never dead-lettered (their own retry rules stay).
- **External source names** `processor`, `saga`, `ingress` and `failed` are refused (the
  library's own families: the `processor:`, `saga:` and `ingress:` markers and the relay's
  `failed:<entry id>` dedupe ids, which a source's `<source>:...` ids must never look like).

**Moving an existing handler into a named processor runs it again over the whole topic.** The
group `<service>.<name>` is new, and a new group starts at the earliest offset the topic still
holds (`auto.offset.reset=earliest`, as for `default` on its first run); its markers
(`processor:<name>:<eventId>`) are a new family, so none of those records is a duplicate to it:
the handler runs once more for every event in the topic's retention. A projection that rebuilds
idempotently may want exactly that; a handler with effects outside MongoDB (an email, a payment
call) repeats every one of them. For such code either leave the handler in `default` and put only
new handlers in the named processor, or commit the new group's offsets at the end of the topic
before you deploy it:
`kafka-consumer-groups --bootstrap-server <broker> --group <service>.<name> --topic <events topic> --reset-offsets --to-latest --execute`
(the group must have no running member). Records produced between that reset and the moment the
old instances stop are handled twice, once by the old `default` and once by the new processor, so
reset right before the rollout. The hub does the same: deploy the new processor paused, then
[reset](#reset-and-replay) it to `latest` and resume it.

### Status

Every status interval (`SNODRA_SERVER_STATUS_INTERVAL_MS`, 5 s) each instance reports one
`ProcessorStatus` per started processor to every hub (in its `InstanceStatus`). The hub shows them in its topology,
`GET /api/v1/processors` and the dashboard's Processors page. `app.processors()` returns the same
list locally.

| Field | Source |
|---|---|
| `state` | STOPPED while its consumer does not run (stopping, or out of the group for a [reset](#reset-and-replay), with `operation_id`); else PAUSED while [paused](#pause-and-resume); else FAILING for 60 s after a record exhausted its attempts, a letter could not be parked (or produced to the DLT), or the consumer reported an error; else STARTING before the first assignment and between a revoke and the next assign (an empty assignment counts: such an instance is RUNNING); else RUNNING |
| `partitions` | the assignment (rebalance callbacks), sorted; per partition `position` (the next offset after the last record this instance acknowledged since the assignment, else -1), `committed` and `high_watermark` (-1 unknown) and `lag` (`high_watermark - committed`, without a commit `high_watermark - position`; -1 unknown; never negative) |
| `committed`, `high_watermark` | read every 5 s **on a blocking thread** with librdkafka's `committed_offsets` and `fetch_watermarks` (2 s timeout each), so a busy handler or a slow broker never stalls the consumer task or the hub stream |
| `processed_total`, `failed_total` | records whose dispatch completed without a stage-1 failure, and records that exhausted their attempts, since start (SEQUENCED and INVALID letters count in neither) |
| `dead_letters` | `countDocuments({processor})` at start, every 30 s and right after this instance parked a letter; 0 unless mode `collection` |
| `last_error`, `last_error_at_ms` | `<error variant>: <message>` of the last failure (never the payload), cut at 512 bytes |
| `event_types`, `dead_letter_mode` | the processor's types (`default` with the saga types), sorted; the mode |
| `operation_id` | the reset holding the processor's lock (empty when none) |
| `replaying`, `partitions[].replay_until` | a replay range is open on one of its assigned partitions; per partition the range's `until` (0 when none) |

Dead letters are covered in [Dead letters](dead-letters.md).

## Processor control

The hub is the control plane of the event processors (ADR 0023, P6b): its HTTP API and its
dashboard pause, resume and reset a processor on every instance at once and work its dead letters
(see the hub's `hub.md`, "Processor control", for the routes and the write token). Each
`ControlRequest` is handled off the hub stream's
read loop (heartbeats and requests never wait for it), one per processor at a time, answered on the
stream it came on and logged at INFO (`control_id`, processor, action, result). Nothing is
configured: no environment variable, no setting.

**The state lives in the service's MongoDB**, collection `processor_control`, one document per
processor (`_id` its name), which every instance reads before its consumer first polls and then
every 5 s; a request is the fast path, the poll is how an instance that missed it (no hub at the
time, started later) converges:

```text
{ _id: "audit", paused: false, pausedAt: null, pausedBy: null,
  operation: { id: "<uuid>", kind: "reset", leaseUntil: Date, preparedAt: Date } | null,
  replay: [ { topic: "kraken.events", partition: 0, from: 120, until: 450 } ],
  updatedAt: Date }
```

Every field is always written (`null` or `[]`); a missing document is a processor that is not
paused, not locked and not replaying. When the document cannot be read at start the consumer does
not start (tried again every 5 s), so a paused processor never consumes because MongoDB was down
for a moment.

### Pause and resume

A pause is written to the document (`pausedBy` the control id, or `local`), then the processor
pauses every assigned partition (rdkafka `pause`) **and keeps polling**: it stays in its consumer
group, no rebalance, and partitions assigned later are paused too. The record being handled
finishes; a record fetched before the pause is sought back, so the resume starts there. Status
`PROCESSOR_PAUSED`. A pause outlives the hubs and restarts: a new instance starts paused. Locally:

```rust,ignore
app.processor_control().pause("audit").await?;   // every instance, within its next poll
app.processor_control().resume("audit").await?;
```

The admin API and dead-letter retries keep working while paused, and **local dispatch** (partner
topics, webhooks, the relay's notices) still runs a paused processor's handlers: a pause is about
Kafka consumption.

### Reset and replay

A reset moves the processor's consumer group to `earliest`, `latest`, a time or explicit partition
offsets, as a **leased operation**: the hub prepares every instance (each takes the processor's lock
in the document, leaves the consumer group and reports `PROCESSOR_STOPPED` with `operation_id`),
one instance executes, then every instance is finished and consumes again (still paused if it was).
The lock is a 30 s lease the hub renews every 10 s; a hub that dies mid-way stops renewing, the
lease passes and the instances release it and consume again by themselves. An instance that starts
(or polls) while an unexpired lock it was not prepared for is held stays out of the group too. A
renewal that arrives after the finish never takes the lock again: an operation that ended on an
instance (finished, aborted, its lease passed, its lock lost) is remembered for at least
max(2 x lease, 60 s), and a prepare of it, or a renewal whose lock is gone, is `NOT_PREPARED`.

The execute resolves the target (`earliest` the low watermarks, `latest` the high watermarks, a
time the first offset at or after it, else the end), refuses while the group has members
(`GROUP_NOT_EMPTY`, nothing changed), and for every partition whose target is below the group's
committed offset makes a **replay range** `[target, committed)` (`latest` never makes one). Then, in
this order: the processor's reset handlers, the deletion of its markers in the ranges, the ranges
written to the document, the offsets committed. rdkafka has no admin call to alter a group's
offsets: the executor commits them with a consumer of the group that never subscribes (the broker
refuses it while the group has members). Right after the reset handlers and again before the
commit the executor must still extend its lease (and be within 120 s), else it stops with `FAILED`
"lease lost: ..." before touching markers or offsets. **A refusal after the reset handlers ran is
not "nothing changed"**: their effects stay, and the message says what else happened, e.g.
`reset handlers ran (2), 37 markers deleted, offsets not moved: retry the reset`.

```rust,ignore
use snodra_messaging::processors::{EventOptions, ResetContext};

SnodraMessaging::builder(config).await?
    .event_in::<OrderPlaced, _, _>("projections", |e, ctx| async move { /* replayed */ Ok(()) })
    // Never runs again in a replay: an effect outside the service (Kotlin's @DisallowReplay).
    .event_with::<OrderPlaced, _, _>(
        EventOptions::new().processor("projections").disallow_replay(),
        |e, ctx| async move { send_confirmation(&e).await },
    )
    // Once per reset that replays something, on the executing instance, before markers and
    // offsets change (Kotlin's @ResetHandler); an error or a panic refuses the reset before any
    // marker or offset changes (what the handlers that ran did stays; the refusal says how many).
    .reset_handler("projections", |ctx: ResetContext| async move {
        clear_projection(&ctx.ranges).await
    })
    .start()
    .await?;
```

- **What a replay runs.** A record of an open range (`from <= offset < until` on its partition) runs
  the processor's stage 1 **without the handlers registered with `disallow_replay`** (its marker is
  still written) and **never the sagas** (stage 2 saw it already). Records at or past `until` are
  normal. A replayed record whose key has a parked letter is parked `SEQUENCED` as usual; a reset
  never touches the dead letters. A record parked while it was replayed keeps that in its letter
  (`replay: true`): its retry runs stage 1 without the `disallow_replay` handlers too.
- **Markers carry a position.** Every marker the Kafka consumer (or a dead letter's retry) writes
  in `processed_events` has `processor`, `topic`, `partition` (Int32) and `offset` (Int64); a
  replay deletes exactly `{processor, topic, partition, offset in [from, until)}`. Markers
  of local dispatch, sagas, ingress and failure notices have none.
- **The ranges end.** Once this instance is past a range's `until` on its partition it removes the
  range from the document; status `replaying` and `replay_until` show the open ones.
- `reset_handler` for a processor without event handlers here fails `start()`.

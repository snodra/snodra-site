# API

## Semantics worth knowing

- **Typed facades.** `Command<R>` and `Query<R>` carry the response type; it is read from the interface type argument at
  runtime. Generic responses such as `List<X>` are erased, so wrap them in a response class.
- **Local short-circuit.** A command or query whose handler lives in the same service is invoked locally and does not go
  through the hub. The handler runs on the caller's thread and coroutine, so it joins the caller's thread-bound
  transaction (a failure in it rolls back the caller's writes too) and sees the caller's security context. A query on a
  type this service declares `@QueryHandler(shared = true)` is the exception: it always goes through the hub (see
  Scatter-gather below), and so is a streaming query (see Streaming queries).
- **Incoming hub requests** run on virtual threads, at most `hub.max-concurrent-handlers` at once, never on the threads
  that read the hub stream; a handler may block (for example on a nested `sendBlocking`).
- **Correlation id.** Every message carries a `correlationId`. Messages sent while handling a hub request or a Kafka
  event reuse the incoming id (carried in the coroutine context and mirrored into the SLF4J MDC key `correlationId`);
  otherwise the MDC value is used, else a fresh UUID.
- **Request ids.** `Request.id` is fresh per attempt. A retried command must carry its own business id in the payload.
- **Identity.** The caller's bearer token is forwarded on the hub path only (`security.forward-jwt`). Requests are
  trusted by default: a request without a token is anonymous and still handled. See [Security](configuration.md#security) for
  `@RequiresAuthentication`.
- **Events** carry `userId` only, not the token. Events published from an `@EventHandler` carry an empty `userId`:
  the consumer has no forwarded token, only the incoming event's `userId` in `MessageContext`.
- **Outbox ordering.** Events with the same key are published in order per publishing instance, using a `seq` field on the
  outbox document.
- **Outbox failures.** A send failure that retrying cannot fix (record too large, serialization, invalid topic,
  authorization) or the `outbox.max-attempts`-th failure marks the document failed (`failedAt`), logs it once at error and
  moves on; other failures stop the batch and are retried on the next poll. Failed documents stay in `outbox` (the TTL
  only removes sent ones); clear `failedAt` and `attempts` to re-queue one.
- **Consumer idempotency.** The consumer records processed event ids in `processed_events` and skips duplicates. A handler
  gets up to `max-attempts` invocations with a 1 s back-off; a record that still fails becomes a dead letter (see
  [Dead letters](#dead-letters)). A payload that does not decode into the handler's class is not retried.
- **Transactions.** The library invokes `@EventHandler`s inside its own Mongo transaction (idempotency marker plus the
  handler's writes), on the Kafka listener thread via `runBlocking`; a handler that relies on it must not switch threads.
  The `MongoTransactionManager` is thread-bound: Spring only carries a transaction across suspensions for reactive
  transaction managers, so a `@Transactional suspend` function loses its transaction at the first real suspension (an
  awaited `send`, `delay`, `withContext` to another dispatcher) and later writes are not part of it. Rules:
  - make `@Transactional` handlers non-suspend functions, or make sure they do not suspend before their last write;
  - `eventBus.publish`/`publishBlocking` only insert into `outbox` and never suspend, so they are safe inside the
    transaction;
  - to send a command or query as well, commit first and send afterwards, for example a non-suspend `@Transactional`
    service method that does the writes, called from the handler, followed by `commandBus.send(...)`:

    ```kotlin
    @CommandHandler
    suspend fun handle(cmd: CloseWorkout, ctx: MessageContext): Unit {
        val workout = workouts.close(cmd.workoutId)          // @Transactional, non-suspend: commits on return
        commandBus.send(NotifyOwner(workout.ownerId))        // after the commit
    }
    ```
- **Shutdown.** The hub connection, outbox publisher and Kafka consumer start before the web server accepts traffic and
  stop after its graceful drain. On stop the instance first announces an empty registration so the hub stops routing to
  it, waits up to 5 s for incoming handlers still running, then closes the stream.
- **Handshake.** `Register` carries `initial_permits` and `client_version` `snodra-messaging/<version>`. The hub answers
  every accepted `Register` with a `RegisterAck` (hub id, heartbeat interval and timeout, default, maximum and per-type
  request timeouts) before the echo of the heartbeat that follows it; the ack of the stream's first `Register` completes
  the handshake and its heartbeat interval is the stream's. A stream without an ack within 10 s
  (`HubProtocol.HANDSHAKE_TIMEOUT`) fails ("registration not confirmed in time") and the connection reconnects.
  `HubConnection.ack` holds the latest ack (per hub: `HubConnections.connections()`). The hub, the protocol and this
  library ship together: a hub and a client of different builds are not supported.
- **Timeouts.** Unless `hub.request-timeout` is set, requests go out with `timeout_ms = 0` and the hub decides (default
  or per-type override). The client gives up locally only when the hub never answers: after the hub's deadline bound
  from the ack (`min(timeout, override or max)`, or `override or max` for 0) plus 1 s, with `MessageTimeoutException`.
- **Dead connections.** A hub stream whose heartbeats stay unanswered for three heartbeat intervals (9 s with the hub's
  default of 3 s) is closed and re-established; HTTP/2 keepalive pings (every 10 s, 5 s timeout, also without calls) run on the
  channel.
- **Lost connections.** A request the stream never accepted (including one still queued on the client when the stream
  broke) fails with `HubUnavailableException` (the handler did not run, retrying is safe; with several hubs it is sent to
  another hub first). A request written to a stream that broke before the answer fails with
  `HubConnectionLostException`: the outcome is unknown, as with a timeout.
- **Flow control.** `Register` carries `initial_permits = hub.max-concurrent-handlers` (at least 1). The hub forwards to
  this instance only against permits and queues the rest per instance, highest `Request.priority` first, each request keeping its own deadline; every completed handler pays
  one permit back on the stream the request arrived on. Permits go back at once while the hub holds at most
  `min(16, initial_permits / 2)` of them for the stream (so a single permit is never held back), otherwise batched (one
  `Permits` message per 16 grants or 50 ms). A slow handler therefore means latency, not timeouts.
- **Busy handlers.** A full hub queue or session buffer answers `HandlerBusyException` (`RESOURCE_EXHAUSTED`): the
  request was rejected before any handler ran, so retrying later is safe.
- **Retry** (opt-in, `hub.retry.*` or `SendOptions.retry`). Only errors `RetryClassification.isRetryable` allows are
  retried: for commands `HubUnavailableException`, `NoHandlerException`, `HandlerBusyException`; for queries also
  `HandlerDisconnectedException`, `MessageTimeoutException`, `HubConnectionLostException`. A command is never retried after
  a timeout or a lost connection (it may have run). Each attempt is a new request (fresh id, same correlation id); all
  attempts share one budget, the chosen timeout or else the hub's deadline for the type (its per-type override or
  default), each sending the remaining budget as `timeout_ms`. A retry starts only if at least
  `max(initial-backoff, 250ms)` of the budget is left after its backoff; otherwise the last error is thrown at once.
  Local handlers (same instance) are never retried.
- **Hub errors.** The hub answers malformed or duplicate in-flight requests with `INVALID_REQUEST`; other hub errors map to
  the exception types in `com.damoreira.snodra.messaging` (`NoHandlerException`, `UnauthenticatedException`, ...).

## Multiple hubs

snodra-server reaches high availability through several independent hubs that never talk to each other (ADR 0016):
every instance connects to every hub, and the client decides where each request goes.

```yaml
snodra.messaging.hub.address: static://hub-1:7000,static://hub-2:7000   # or: dns:///snodra-server:7000
```

- **One connection per hub.** `HubConnections` opens one `Connect` stream per target, each with its own handshake,
  heartbeat and reconnect backoff, and sends the identical `Register` on every one (re-sent on every
  reconnect). One target behaves exactly like the single-hub client.
- **Targets.** A comma-separated list (blank entries and repeats dropped, order kept), or a single `dns:///name:port`
  (port required, not combinable with other entries) resolved at start and every 30 s: a new address gets a connection,
  a vanished one first announces an empty registration, then is closed once idle (at most 30 s later); an address that
  comes back before its connection is closed revives that connection instead of dialing a second one. Only one address
  family is used (rule shared with the Rust library): the IPv4 addresses when the answer has any, else the IPv6 ones,
  repeats dropped; a dual-stack name lists every hub under both families, and two streams to one hub with the same
  instance id would replace each other. A failed or empty resolution keeps the current connections.
- **Hub identity.** A hub is its `RegisterAck.hub_id`; an ack with an empty id is its target id: the bare `host:port` without `static://` (a resolved IPv6 address as `[ip]:port`, without zone; rule shared with
  the Rust library). When
  two targets answer the same id, the one that acknowledged first owns it for as long as it is kept, live or
  reconnecting, and the other is closed and parked (logged once). The hub keeps one session per instance id, so the
  second target's `Register` ends the first one's stream before its own ack arrives; the owner reconnects and the
  duplicate never takes over, so the two cannot evict each other back and forth. A parked target is retried only once
  its owner is gone (a DNS address no longer resolved, or a target now answering another id). Each hub replica needs
  its own `SNODRA_SERVER_ID`: replicas sharing one id are taken for one hub, and all but one are parked.
- **Live hubs** are the kept connections whose stream completed its handshake.
- **Routing.** A request without a routing key goes round-robin over the live hubs; a hub that is reconnecting is
  skipped. A request with a routing key (`SendOptions.routingKey`) goes to the live hub with the highest rendezvous score
  for (routing key, hub id), so a key keeps its hub while the hubs are stable and only the keys of a hub that leaves
  move; the hub's own consistent-hash ring then keeps it on one instance. Replies always go back on the stream the
  request arrived on.
- **Rendezvous score** (identical in the Rust library): `fmix64(fnv1a64(utf8(hub_id + "\u0000" + routing_key)))`, compared
  as unsigned 64-bit; equal scores go to the smaller hub id. `fnv1a64` is 64-bit FNV-1a (offset basis
  `0xcbf29ce484222325`, prime `0x100000001b3`); `fmix64` is MurmurHash3's 64-bit finalizer (`k ^= k >>> 33;
  k *= 0xff51afd7ed558ccd; k ^= k >>> 33; k *= 0xc4ceb9fe1a85ec53; k ^= k >>> 33`). Vectors: `score("hub-a",
  "order-1") = 0xd8d5618ff3a93f55`, `score("hub-b", "key-0") = 0xbd443f5acaf98254` (`RendezvousTest`).
- **Failover.** A request its hub could not take before it was written (the stream had just closed, or broke while the
  request was still queued on the client) is sent to another live hub; with no hub left the call waits for one. The
  call has one deadline: its own timeout (`SendOptions.timeout`, else `hub.request-timeout`; 5 s when neither is set);
  waiting ends there with `HubUnavailableException`, and a request sent again carries what is left of its
  `timeout_ms`, so failover never stretches a call beyond its timeout. A request already written fails with `HubConnectionLostException` (or the hub's `HandlerDisconnectedException`), and the retry policy
  applies. With no live hub at all: `HubUnavailableException`, as with one hub.
- **Permits.** A stream announces `ceil(hub.max-concurrent-handlers / N)` initial permits, where N = 1 (the hub being
  registered on) + the other hubs that are live or still on their first connect attempt (a hub down after a failed
  attempt is not counted). Whenever that count changes, every live stream is topped up to its current share:
  `Permits{count = max(0, ceil(max / N) - offered), grant = ceil(max / N)}`, offered = the stream's `initial_permits`
  plus its earlier top-ups; the grant raises the hub's permit cap on the session (otherwise its `initial_permits`) so
  the hub keeps the top-up. So with two hubs the
  survivor of an outage (or of a hub that failed its first attempt) serves at full capacity, flaps never add up, a hub
  that joins or returns gets `ceil(max / N)` on its new stream, and nothing is ever revoked (rule shared with the Rust
  library). Locally at most `hub.max-concurrent-handlers` handlers run in total, whichever hub sent the requests. Permits are paid back per stream.
- **Readiness.** `HubConnections.awaitRegistered(timeout)` is true only once **every** kept hub confirmed the latest
  registration; while one configured hub is down it returns false at the timeout, although the instance is already
  served by the others (`connected` / `liveHubIds()` tell that). The Rust library's equivalent may differ; see its
  README.
- **Status.** Every `hub.status-interval`, and whenever the live set changes, each live hub gets an `InstanceStatus`:
  `connected_hub_ids` (the ids of the live hubs), `handlers_in_flight` (over all hubs) and the event processors. The hub shows
  the report in its topology (`connectedHubIds`, `statusAgeMs`) and the dashboard flags instances missing a hub.
- **Shutdown** announces the empty registration on every hub, waits for the handlers, then closes every stream.

## Scatter-gather

A query type can be **shared** by several services (ADR 0017): any number of services may own it.
A point query (`queryBus.send`) on a shared type goes to one instance of any owner (the hub round-robins over all of
them, also when the sender is itself an owner: a shared type is never short-circuited to the local handler); a
**scatter-gather** asks every live instance of every owner and returns what they answered.

```kotlin
@Component
class CatalogueSearch {
    @QueryHandler(shared = true) // every service that can answer declares it shared
    fun handle(q: SearchEverything): SearchHits = SearchHits(index.search(q.text))
}

// Every answer that arrived by the deadline, in arrival order:
val result: ScatterResult<SearchHits> = queryBus.scatterGather(
    SearchEverything("legs"),
    ScatterOptions(timeout = Duration.ofSeconds(2), maxResults = 0, priority = null),
)
result.parts.forEach { part -> println("${part.service}/${part.instance}: ${part.result ?: part.error}") }
println("${result.results.size} answers, ${result.failed} failed, ${result.timedOut} timed out")

// The same as a Flow: each part as it arrives; completes on the end.
queryBus.scatterGatherFlow(SearchEverything("legs")).collect { part -> render(part) }
```

- **API.** `suspend fun <R> scatterGather(query: Query<R>, options: ScatterOptions = ScatterOptions()): ScatterResult<R>`
  and `fun <R> scatterGatherFlow(query: Query<R>, options: ScatterOptions = ScatterOptions()): Flow<ScatterPart<R>>`.
  `ScatterOptions(timeout: Duration? = null, maxResults: Int = 0, priority: Int? = null, retry: RetryPolicy? = null)`,
  `ScatterResult<R>(parts, failed, timedOut)` (plus `results`, the successful values), `ScatterPart<R>(service,
  instance, result: R?, error: RemoteHandlerException?)`. The flow carries no counts: use `scatterGather` when
  `failed` / `timedOut` matter.
- **Targets.** Every live instance of every owner of the type; on an exclusive type, every instance of its one owner.
  The gather always goes through the hub, also when this instance owns the type (it is one of the targets then).
  Handlers need nothing new: each target receives an ordinary request (id `<id>#<n>`) and answers it as usual.
- **Results.** One part per target that answered, successes and failures, in arrival order. A failed part carries a
  `RemoteHandlerException` whose `code` is the hub's (`HANDLER_ERROR` for a handler exception, `HANDLER_DISCONNECTED`,
  `RESOURCE_EXHAUSTED`, ...); a part whose payload does not decode into `R` is a failed part too (code
  `ERROR_CODE_UNSPECIFIED`), never a failure of the whole call, so `failed` counts every part with an error. Targets
  that had not answered by the deadline count in `timedOut`. Partial answers are answers: check `failed + timedOut`
  for "all or nothing".
- **Options.** `timeout` is the deadline of the whole gather (same rules as `SendOptions.timeout`: default
  `request-timeout`, else the hub's default; zero is unset). `maxResults > 0` ends the gather after that many
  successful parts. `priority` applies to every target request.
- **Errors.** No owner: `NoHandlerException`; a command type: `InvalidMessageException`. With several hubs a gather
  goes to one hub (round-robin). If the stream to that hub breaks before the end the call fails with
  `HubConnectionLostException`.
- **Retry.** The configured or per-call `RetryPolicy` applies to the whole gather with the query rules
  (`HubConnectionLostException`, `NoHandlerException`, ... are retryable). A retried gather is a new gather: its result
  holds only its own parts. The flow retries only until its first part; after that an error ends the flow, so no part
  is ever emitted twice.
- **Shared registration.** Every registrant of a type must agree: exclusive by one and shared by another (even within
  one service) is refused by the hub with `ALREADY_EXISTS` at register time, logged and surfaced like any registration
  conflict (`HubRegistrationRejectedException` from `awaitRegistered`). One service declaring a type both ways fails at
  startup. Commands are never shared.

## Streaming queries

A **streaming query** (ADR 0017, P4b) is answered by one handler instance as a stream of parts under the collector's
back-pressure: an export, a long listing, a search that trickles. The query implements `StreamingQuery<R>` (`R` is
the element type), the handler returns `Flow<R>`, and the caller collects a `Flow<R>` from `queryBus.stream`.

```kotlin
@MessageType("workouts.ExportWorkouts")
data class ExportWorkouts(val ownerId: String) : StreamingQuery<WorkoutRow>

@Component
class WorkoutExport(private val repo: WorkoutRepository) {
    @QueryHandler // shared = true works here too: one instance of any owner answers
    fun handle(q: ExportWorkouts): Flow<WorkoutRow> = repo.streamByOwner(q.ownerId).map { it.toRow() }
}

// Each part as the handler produces it, paced by credits; completes when the handler's flow does.
queryBus.stream(ExportWorkouts(ownerId), StreamOptions(initialCredit = 32, timeout = Duration.ofSeconds(30)))
    .collect { row -> writer.write(row) }
```

- **API.** `fun <R> stream(query: StreamingQuery<R>, options: StreamOptions = StreamOptions()): Flow<R>` and
  `StreamOptions(timeout: Duration? = null, maxResults: Int = 0, priority: Int? = null, initialCredit: Int = 64,
  retry: RetryPolicy? = null)`. The flow is cold and unbuffered: each collection sends one request, and the next part
  is read only after the collector consumed the previous one. A controller may return the flow: the caller's bearer
  token and trace context are read when `stream` is called, not when the flow is collected.
- **Handler.** `@QueryHandler` (plain or `shared = true`) on a method taking the `StreamingQuery<R>` (optionally with
  a `MessageContext`) and returning `Flow<R>`; another return type, `@CommandHandler`, or a `Flow` returned for a plain
  `Query`, fails at startup. The library
  collects the flow and sends one part per element, **suspending the collection inside `emit` while the hub granted no
  credit**, then the end. An exception from the flow ends the stream with the handler's error, mapped exactly like a
  unary failure (`HANDLER_ERROR` with `IllegalArgumentException` / validation details, `AccessDeniedException`, ...);
  `@RequiresAuthentication` is checked before the flow starts. The handler counts against `max-concurrent-handlers`
  for the whole stream. A part that waits for credit longer than `hub.stream-credit-timeout` (10 min by default, the
  hub's default maximum stream duration) means the hub forgot the stream (a race, a lost `Flow` or `Cancel`): the
  library ends it with `TIMEOUT` ("no credit within ... ms"), the flow seeing a `CancellationException` as at a hub
  `Cancel`, and frees the handler slot and the hub permit.
- **Routing.** Always through the hub, also when this instance owns the type: one instance of the owner (one of every
  owner's instances on a shared type), chosen like a point query. A `StreamingQuery` is not a `Query`: it cannot be sent with `send` or gathered, and a unary request
  that reaches a streaming handler is answered `INVALID_REQUEST`.
- **Credits.** `initialCredit` is the window: the handler may run that many parts ahead of the collector. Each time
  the collector consumed half of the window the library grants `initialCredit / 2` more (a `Flow` message), so a
  collector that keeps up never stalls the handler and a slow one holds it at the window. A handler sending beyond its
  credit (never this library) ends the stream with `INVALID_REQUEST`.
- **Options.** `timeout` is the **idle** timeout: the hub ends the stream with `TIMEOUT` when no part arrives within it
  (reset by every part; a queue wait at the hub counts too; it does not run while the credit is 0, so a collector that
  holds the handler at the window is never an idle handler), same defaults as `SendOptions.timeout`. It is sent whole
  as `timeout_ms` on every attempt: with retry the budget bounds the attempts before the first part (and, with several
  hubs, the wait for a live one), never the idle timeout the stream runs with. `maxResults > 0`
  ends the stream after that many parts (the hub cancels the handler). `priority` is the forwarded request's. The hub
  also bounds a stream's whole life (`SNODRA_SERVER_MAX_STREAM_DURATION`, 10 min by default): `CANCELLED`.
- **Errors.** Before any part, as for a unary query: no owner `NoHandlerException`, a command type
  `InvalidMessageException`; with several hubs the stream goes to one hub (round-robin). An end with an error fails the
  flow **exactly like a unary `send` fails on the same hub code**: `HANDLER_ERROR` (the handler's flow failed)
  `RemoteHandlerException`, `TIMEOUT` (idle) `MessageTimeoutException`, `HANDLER_DISCONNECTED` (the instance left
  mid-stream: a stream never moves to another instance) `HandlerDisconnectedException`, `RESOURCE_EXHAUSTED` (the
  instance's hub queue was full) `HandlerBusyException`, `INVALID_REQUEST` `InvalidMessageException`, and `CANCELLED`
  (the hub's maximum stream duration) the new `StreamCancelledException`. The parts emitted before it stay emitted. A
  part that does not decode into `R` fails the flow with `InvalidMessageException` and cancels the stream. The stream
  to the hub breaking mid-stream is `HubConnectionLostException`. Parts carry the handler's `seq` (1, 2, 3, ...) and
  the end carries the hub's count of parts: the hub drops a part it could not deliver within 5 s on a full buffer, so
  the library checks both and fails the flow with `InvalidMessageException("stream <type> lost N part(s)")` on a jump
  in `seq` (the stream is cancelled) or an end counting more parts than arrived (the stream had ended; nothing is sent).
  An exception thrown **by the collector** is the collector's own failure and reaches it unchanged, also when it is a
  `HubUnavailableException` or `HubConnectionLostException` of a nested send inside `collect {}`: the stream is
  cancelled and never moved to another hub, since its request was written.
- **Cancel.** Cancelling the collector (`take(n)`, a cancelled coroutine) or throwing in it sends `Cancel` to the hub,
  which cancels the handler's coroutine (its flow sees a `CancellationException`); nothing of the stream follows. The
  hub cancels the handler the same way at `maxResults`, at the idle timeout, at the max duration and when the
  collector's instance disconnects (`sender disconnected`); the handler's own hub stream closing cancels its streams
  too. A hub `Cancel` also stops a unary or gather handler whose answer is no longer wanted (a gather past
  `maxResults` or its deadline, or whose sender disconnected). A blocking (non-`suspend`) handler is not interrupted
  by any of these: it runs to its end and its reply is dropped; only a suspending handler stops at its next suspension
  point.
- **Retries.** The configured or per-call `RetryPolicy` applies with the query rules only until the first part, to an
  end with an error as to an error before any part (`HandlerDisconnectedException`, `MessageTimeoutException`,
  `HandlerBusyException`, `NoHandlerException`, `HubConnectionLostException`, ... are retried; handler errors,
  `StreamCancelledException` and the rest are not): a retried stream is a new request (fresh id; with several hubs,
  round-robin to another one), so no part is ever emitted twice. After the first part nothing is retried: the
  flow throws, a broken hub stream as `HubConnectionLostException`. The budget covers the attempts up to the first part
  (and the wait for a live hub); every attempt sends the chosen `timeout` whole as its idle timeout, never what is
  left of the budget.

## Subscription queries

A **subscription query** (ADR 0017, P4c) is an initial result followed by the updates the handlers push, until the
subscriber cancels or the handlers complete: a screen that shows an account and refreshes when it changes, a status page.
The query implements `SubscriptionQuery<I, U>` (`I` the initial result, `U` an update), the handler returns the initial
result `I`, every handler instance pushes updates through the `QueryUpdateEmitter`, and the caller gets a
`SubscriptionResult<I, U>` from `queryBus.subscribe`.

```kotlin
@MessageType("accounts.WatchAccount")
data class WatchAccount(val accountId: String) : SubscriptionQuery<AccountView, AccountChanged>

@Component
class AccountWatch(private val repo: AccountRepository) {
    @QueryHandler // shared = true works here too
    fun handle(q: WatchAccount): AccountView = repo.view(q.accountId) // the initial result
}

@Service
class Accounts(private val repo: AccountRepository, private val emitter: QueryUpdateEmitter) {
    @Transactional
    fun deposit(accountId: String, amount: Money) {
        val account = repo.deposit(accountId, amount)
        // Inside the transaction: delivered after the commit, dropped on a rollback.
        emitter.emit<WatchAccount, AccountChanged>({ it.accountId == accountId }, AccountChanged(accountId, account.balance))
    }
}

// Returns once the initial result arrived; the updates follow as a flow.
val result = queryBus.subscribe(WatchAccount("acc-1"), SubscriptionOptions(initialCredit = 32))
render(result.initial)
result.updates.collect { change -> render(change) }   // completes when the handlers do; cancel() or take(n) cancel it
```

- **API.** `suspend fun <I, U> subscribe(query: SubscriptionQuery<I, U>, options: SubscriptionOptions =
  SubscriptionOptions()): SubscriptionResult<I, U>` and `SubscriptionOptions(timeout: Duration? = null, maxResults: Int =
  0, priority: Int? = null, initialCredit: Int = 64, retry: RetryPolicy? = null)` (`maxResults >= 0`, `initialCredit >= 1`).
  `SubscriptionResult(val initial: I, val updates: Flow<U>)` has `fun cancel()`; `initial` is a value, `subscribe` having
  returned only once the initial part arrived. A controller may return `updates` (an SSE endpoint): the caller's bearer
  token and trace context are read when `subscribe` is called, not when the flow is collected.
- **Handler.** `@QueryHandler` (plain or `shared = true`) on `fun handle(q: SubscriptionQuery<I, U>[, ctx: MessageContext]): I`
  answers the **initial result**; a handler returning a `Flow`, or `@CommandHandler` on a subscription query, fails at
  startup. The hub sends every live instance of the type a `SUBSCRIPTION` request, and the library registers the
  subscription (the decoded query, its request id and the hub stream it came from); the initial result is a separate
  ordinary request answered by the same method, which the library recognises by the hub's request id (`<id>#0`). A unary
  request for the type is answered `INVALID_REQUEST` ("is a subscription query: send it with QueryBus.subscribe"), a
  `SUBSCRIPTION` request for a type without a subscription handler ends with `INVALID_REQUEST`, and
  `@RequiresAuthentication` is checked when the subscription is registered and again on the initial request.
- **`QueryUpdateEmitter`.** An auto-configured bean: `emit(queryType, filter, update)`, `complete(queryType, filter)` and
  `completeExceptionally(queryType, filter, cause)`, plus reified overloads (`emitter.emit<WatchAccount, AccountChanged>(
  { it.accountId == id }, update)`, `emitter.complete<WatchAccount> { it.accountId == id }`). They deliver to every open
  subscription of that type **on this instance** whose decoded query passes `filter`, in call order: an update is one
  part (encoded with the library codec), `complete` ends the subscription cleanly, `completeExceptionally` ends it with
  `HANDLER_ERROR` and `"<SimpleName>: <message>"` (the subscriber's flow fails with a `RemoteHandlerException`), and both
  remove it. With no matching subscription the call does nothing, so a service may emit unconditionally. A filter that
  throws skips its subscription (logged), never the others.
- **Transactions.** Inside an active Spring transaction (`TransactionSynchronizationManager.isActualTransactionActive()`:
  `@Transactional`, `TransactionTemplate`) every emit and complete is deferred to `afterCommit` and dropped on rollback,
  so a subscriber never sees an update of data that was never committed; the open subscriptions and the filter are
  evaluated at delivery, after the commit, and a failure there is logged, never thrown at the committer. Outside a
  transaction delivery is immediate, and a reactive (Reactor-context) transaction is not seen.
- **Targets, and the at-most-once caveat.** Every live instance of every owner, **as they are
  when the subscription opens**: an instance that registers later is never added (an update emitted on a new instance is
  lost to that subscriber), a target that leaves is not replaced, and the hub never resubscribes. After a rolling
  restart a subscription listens to fewer instances than serve the type, silently until the last one leaves
  (`HandlerDisconnectedException`); a subscriber that needs every instance resubscribes. One of them, chosen like a point
  query, answers the initial result. A subscription is passive: it holds no handler permit, waits in
  no hub queue and is not counted as an in-flight request after the initial result.
- **Credits and the hub's buffer.** `initialCredit` is the window: the hub relays that many parts (the initial result
  included) before the collector consumed any, and holds further updates for the subscriber, at most 256
  (`SNODRA_SERVER_SUBSCRIPTION_BUFFER`). One more ends the subscription with `RESOURCE_EXHAUSTED`, which the flow throws as a
  `HandlerBusyException` carrying the hub's reason; what the hub buffered is dropped. The library grants `initialCredit /
  2` more each time that many parts were consumed, the initial result counting as consumed once `subscribe` returned
  it (so a window of 1 cannot stall). No credit goes to the handlers: updates are pushed, an emitter is shared by every
  subscriber of its instance, and a slow subscriber is the hub's problem, not theirs. A result that is **dropped without
  being collected** leaves the hub buffering until it reaches that limit and ends the subscription; collect it or
  `cancel()` it.
- **Options.** `timeout` bounds the **initial result** only (the hub queue wait plus the handler), sent as `timeout_ms`
  with the same defaults as `SendOptions.timeout`; there is no idle timeout, a quiet subscription is not a broken one.
  `maxResults > 0` ends the subscription after that many **updates** (the initial result does not count) with a clean end
  and cancels the handlers' side. `priority` is the initial request's. The hub may bound a subscription's whole life
  (`SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION`, off by default): `StreamCancelledException`.
- **Errors.** `subscribe` fails before the initial result as a unary query does: no owner `NoHandlerException`, a command type
  `InvalidMessageException`, the initial request failing `RemoteHandlerException` / `MessageTimeoutException` /
  `HandlerDisconnectedException`, an instance already serving its limit (the hub's, or this library's
  `hub.max-subscriptions`) `HandlerBusyException`. After it, `updates` completes on a clean end and throws what a unary
  error with the same code throws: `HANDLER_ERROR` (`completeExceptionally`, or a failing target) `RemoteHandlerException`,
  `HANDLER_DISCONNECTED` (the last handler instance left) `HandlerDisconnectedException`, `RESOURCE_EXHAUSTED`
  `HandlerBusyException`, `CANCELLED` `StreamCancelledException`; the stream to the hub breaking is
  `HubConnectionLostException`. An update that does not decode into `U` fails the flow with `InvalidMessageException` and
  cancels the subscription; an initial result that does not decode fails `subscribe` the same way and cancels it. The
  library checks the parts' `seq` (the hub numbers them 1, 2, 3, ...) and the end's `parts` count: a gap fails the flow with
  `InvalidMessageException("subscription <type> lost N part(s)")`.
- **Cancel.** Cancelling the collector (`take(n)`, a cancelled coroutine), throwing in it, or `SubscriptionResult.cancel()`
  sends `Cancel` to the hub once, which cancels every target: the handlers' subscriptions are removed. `cancel()` also
  completes `updates`; `updates` can be collected **once**. On the handler side a hub `Cancel` removes the subscription, a lost
  hub stream removes every subscription it carried (the hub forgot them, and they are not restored on reconnect), and
  shutting the application down ends them with a clean `ReplyEnd` (best effort: the subscriber's flow completes once every
  other target has too, or fails with `HandlerDisconnectedException` if the stream closed first).
- **Retries.** The configured or per-call `RetryPolicy` applies with the query rules only until the initial result, to an
  end with an error and to a gate `Error` as to an error before any part (`NoHandlerException`, `HandlerBusyException`,
  `HandlerDisconnectedException`, `MessageTimeoutException`, ... are retried; handler errors and the rest are not): a retried
  subscription is a new request with a fresh id (with several hubs, round-robin to another one), so no update is
  delivered twice. After the initial result nothing is retried; resubscribing is the caller's call (it gets a fresh
  initial result).
- **Several hubs.** A subscription goes to one hub (round-robin), chosen and failed over like a gather.

## Sagas

A saga is a long-running process that reacts to events, keeps its own state, sends commands and events, waits for an answer and
handles the answer that never comes. It is Axon's `@Saga` model (`@StartSaga`, `@SagaEventHandler` with association properties,
`@EndSaga`, deadlines), built mainly to drive **integrations with external systems**. Sagas run inside your service, against its
MongoDB and its Kafka consumer; the hub is not involved except to carry the commands a saga sends to another service.

Everything starts and ends with Snodra messages. A saga never calls an external system itself: it sends a command, an
**adapter** in the same service (an ordinary `@CommandHandler` made idempotent) makes the call, and the external system's answer
comes back as an ordinary Snodra event through a partner topic, a webhook or polling. The full model, the delivery guarantees,
the configuration and the metrics are in [Sagas and deadlines](../index.md#sagas-and-deadlines); the decision and every
builder ruling are in ADR 0021 (sagas in the library); a working example with a fake partner is in
`snodra-messaging/examples/README.md` ("The postcard saga").

## A minimal saga

```kotlin
@Saga
class PaymentSaga {
    var orderId: String? = null                 // state: plain properties, persisted as JSON after each handled message
    var paymentRef: String? = null
    var timeoutDeadline: String? = null

    @StartSaga
    @SagaEventHandler(associationProperty = "orderId")
    fun on(e: OrderPlaced, saga: SagaLifecycle, commands: SagaCommands, deadlines: DeadlineManager) {
        orderId = e.orderId
        paymentRef = "pay-${e.orderId}"
        saga.associateWith("paymentRef", paymentRef!!)             // later events are routed here by paymentRef
        commands.send(RequestCharge(paymentRef!!, e.amount))       // recorded now, sent after the commit
        timeoutDeadline = deadlines.schedule(Duration.ofMinutes(15), "charge-timeout")
    }

    @EndSaga
    @SagaEventHandler(associationProperty = "paymentRef")
    fun on(e: ChargeSucceeded, deadlines: DeadlineManager) {
        timeoutDeadline?.let(deadlines::cancel)
    }

    @EndSaga
    @SagaEventHandler(associationProperty = "sagaId")
    fun on(e: SagaCommandFailed, commands: SagaCommands) {
        commands.publish(OrderPaymentFailed(orderId!!, e.reason.name), key = orderId)
    }

    @EndSaga
    @DeadlineHandler("charge-timeout")
    fun timeout(commands: SagaCommands) {
        commands.send(CancelCharge(paymentRef!!))
    }
}
```

- The class needs a no-argument constructor and is found by scanning the application's packages (the packages of your
  `@SpringBootApplication` class). It is not a Spring bean. Put it in the service's own package, not in a library.
- `@SagaEventHandler(associationProperty = "orderId")` looks the event's `orderId` up as the association `orderId = <value>` among
  the live instances; every match handles the event. `keyName` renames the association, `associationHeader` routes by a message
  header instead, `payloadType` narrows a handler declared on a supertype.
- `@StartSaga` creates an instance when no live instance matched the event; with `forceNew = true` it always does. At most one live
  instance exists per start association otherwise.
- Handler parameters after the event: `SagaLifecycle`, `SagaCommands`, `DeadlineManager`, `MessageContext` and any Spring bean by
  type, in any order. A `@DeadlineHandler`'s first parameter, when it is not one of those, receives the deadline's payload.
- Handlers are plain (non-`suspend`) functions: they run inside the saga's thread-bound Mongo transaction. Several handlers of one
  event type run in **method-name order**.
- `commands.send` and `commands.publish` only record the message; it leaves **after** the transaction committed, in call order,
  at least once, with the header `idempotency-key = <sagaId>:<seq>`. A saga does not wait for a reply.
- State, associations, scheduled deadlines and recorded messages are written together, once, after the handlers returned. An
  exception rolls all of it back and the event is retried (5 attempts), then parked (see [Operating sagas](#operating-sagas)).
- The startup fails, naming the class and method, for a suspend handler, a saga without a `@StartSaga` handler, an association
  property that does not exist on the event, a handler parameter nothing can fill, and a state the library's codec cannot write
  and read back.

## An idempotent adapter

The saga's `RequestCharge` is handled by an adapter in the same service. `@IdempotentHandler` records the call in
`external_calls` under the command's idempotency key, so a command the relay sends twice (a crash between sending and marking it
sent) reaches the external system once:

```kotlin
@Component
class PaymentAdapter(private val gateway: PaymentGateway) {

    @CommandHandler
    @IdempotentHandler                                             // key: the idempotency-key header (<sagaId>:<seq>)
    fun charge(cmd: RequestCharge, ctx: MessageContext) {
        val key = checkNotNull(ctx.headers["idempotency-key"])
        try {
            gateway.charge(cmd.paymentRef, cmd.amount, idempotencyKey = key)        // pass the key on when the partner takes one
        } catch (e: GatewayUnavailable) {
            throw RetryableExternalException("gateway down: ${e.message}", e)      // the relay backs off and calls again
        }
    }
}
```

- Throw `RetryableExternalException` for a failure a later attempt may cure (a timeout, a 503, a 429). **Do not retry inside the
  adapter**: the saga relay owns the backoff (`sagas.relay.*`), so retries never stack and no relay thread sleeps in your code.
  Any other exception is permanent: it is stored, repeats of the key throw it again, and the saga hears `SagaCommandFailed(FAILED)`.
- If the process dies in the middle of a call, the record stays `IN_PROGRESS`. After `external.calls.lease` (5 minutes) the
  outcome is unknown. By default (`externalIdempotent = false`) the call becomes `UNKNOWN`, is never repeated on its own and the
  saga hears `SagaCommandFailed(UNKNOWN_OUTCOME)`, so it decides (poll the partner, compensate, ask a person). If the partner
  de-duplicates by the key you pass it, declare `@IdempotentHandler(externalIdempotent = true)` and the call is repeated. Throw
  `ExternalCallUnknownOutcomeException` yourself when you see a connection break after the request went out: the record stays
  `UNKNOWN` and a redelivery reports it again. A call that ran but whose `SUCCEEDED` could not be written (the store went away)
  is an unknown outcome too, never a failed call (retryable with `externalIdempotent = true`). A call that outlives its lease
  no longer owns the record (its writes match on the `attempts` it set): it never overwrites or deletes the record of the call
  that took over or gave it up, and a body that returned then reports an unknown outcome (retryable with `externalIdempotent = true`).
- `@IdempotentHandler(key = "'poll:' + message.jobId + ':' + message.attempt")` takes a SpEL key over `message` and `headers`.
- The handler must not be `suspend`. Use `eventBus.publishBlocking(...)` to publish a result.
- The interceptor and its collection exist when a class in the application's packages has an `@IdempotentHandler` method; set
  `snodra.messaging.external.calls.enabled=true` for an adapter outside them.
- A saga command carries **no user token**: it only reaches handlers without `@RequiresAuthentication` (the same limit as events
  published from handlers, see [Known limitations](modules.md#known-limitations)); otherwise the saga hears `SagaCommandFailed(DENIED)`.

## Every handler of a saga command must be idempotent

The relay retries after a timeout or a lost connection (the command may or may not have run, and a saga command carries an
`idempotency-key`, so a retry is safe for an idempotent target), and re-sends after a crash between sending and marking it sent.
**A handler of a saga command that is neither an `@IdempotentHandler` nor naturally idempotent can run twice** for one command.
Use `@IdempotentHandler`, or make the effect idempotent on `headers['idempotency-key']` yourself.

Two more things about the adapter:

- The body of an `@IdempotentHandler` **`@EventHandler`** runs inside the ordinary handlers' stage-1 Mongo transaction, so a slow
  call there holds that transaction open (MongoDB's lifetime limit, 60 s by default, applies). The `@CommandHandler` adapter the
  relay calls runs in no Mongo transaction: prefer it for anything slow.
- `idempotency-key` is just a header that any sender of the command can set, a hub client that is not a saga included. Keep
  adapters internal: do not expose their command types to services or clients you do not trust.

## Failed commands: `SagaCommandFailed`

A command that failed for good comes back to the saga as the event `SagaCommandFailed(sagaId, commandType, idempotencyKey, reason,
message)`, delivered locally (never published to `snodra.events`). `reason` is `NO_HANDLER`, `DENIED`, `INVALID`, `FAILED`,
`UNKNOWN_OUTCOME` or `EXHAUSTED` (transient failures that outlasted `sagas.relay.max-attempts`). The runtime delivers it to the
saga instance that sent the command **by its id**: the saga needs no association, only a handler
(`@SagaEventHandler(associationProperty = "sagaId")`, the name of the event's property; a saga that also associated itself with
`sagaId` keeps working). When the saga type has no handler for it, or the saga has ended, and no ordinary `@EventHandler` took
it either, it is logged at error and counted in `snodra.saga.command.failures`. A permanently failed step does not hold back
the saga's later steps.

## Hearing from the partner: a topic of its own

When the partner produces to **its own Kafka topic** (not `snodra.events`):

```yaml
snodra:
  messaging:
    external:
      kafka:
        sources:
          printer:                       # the source's name
            topic: printer.events
            # bootstrap-servers: partner-kafka:9092   # default: snodra.messaging.kafka.bootstrap-servers
            # properties: { security.protocol: SSL }  # extra consumer properties
```

```kotlin
@Component("printer")                    // the bean carries the source's name
class PrinterTranslator(private val codec: JsonCodec) : ExternalRecordTranslator {
    override fun translate(record: ConsumerRecord<String, ByteArray>): TranslatedEvent? {
        val n = codec.decode(record.value(), PrinterNotification::class)
        return TranslatedEvent(PostcardPrinted(n.jobId, n.name), dedupeKey = n.deliveryId)    // null ignores the record
    }
}
```

The library runs one consumer per source (group `<service-name>.external.<name>`, `earliest` for a new group), translates each
record and dispatches the event **locally**: the service's `@EventHandler`s and sagas, never `snodra.events`. The `dedupeKey` (the
partner's own id) makes two records for one event apply once; without it the key is `<name>:<partition>:<offset>`. A translator
exception retries the record up to `kafka.consumer.max-attempts` times, then logs and skips it. `properties` cannot set the
servers, the group id, the deserializers or auto-commit: such an entry fails the startup, naming it. `kafka-clients` is an `api` dependency of the starter, so the
translator's `ConsumerRecord` compiles without declaring it.

## Hearing from the partner: a webhook

The library gives the verifier and the ingress; the service writes the endpoint (authentication, body shape and response codes
differ per partner). The five-line controller:

```kotlin
@RestController
class PartnerWebhook(private val verifier: WebhookSignatureVerifier, private val ingress: ExternalEventIngress,
                     private val codec: JsonCodec, @Value("\${partner.webhook-secret}") private val secret: String) {
    @PostMapping("/partner/webhook")
    fun receive(@RequestBody body: ByteArray, @RequestHeader headers: HttpHeaders): ResponseEntity<Void> {
        if (!verifier.verify(secret, null, headers.toSingleValueMap(), body)) return ResponseEntity.status(401).build()
        val n = codec.decode(body, PartnerNotification::class)
        ingress.accept("partner", n.deliveryId, PostcardPrinted(n.jobId, n.name))   // ACCEPTED or DUPLICATE: both are a 200
        return ResponseEntity.ok().build()
    }
}
```

- `verify(secret, previousSecret, headers, body)` accepts the shared secret in `X-Snodra-Webhook-Secret` or the HMAC-SHA256 of the
  **raw** body in `X-Snodra-Signature` (hex, or `sha256=<hex>`); the previous secret is accepted during a rotation; constant-time
  comparison; an empty secret verifies nothing. Verify the raw bytes before parsing.
- `accept(source, dedupeKey, event, headers = emptyMap())` dispatches locally and **synchronously** (handlers, then sagas) under
  the id `<source>:<dedupeKey>`, so the partner's retries apply once (`DUPLICATE`). Use the partner's own delivery or event id as
  `dedupeKey`. A failure is thrown: answer 5xx and let the partner retry. An event no handler or saga takes is `ACCEPTED` with a
  warning. It blocks: call it from a request thread.

## Hearing from the partner: long polling

When the partner offers neither: the saga schedules a polling deadline, the deadline handler sends a poll command, the adapter
asks the partner and publishes a result event when there is one, and the saga reschedules or ends. The adapter's key includes the
poll attempt, so a poll sent twice asks once:

```kotlin
// in the saga
@DeadlineHandler("poll-printer")
fun poll(commands: SagaCommands, deadlines: DeadlineManager) {
    commands.send(PollPrintJob(jobId!!, ++polls))
    deadlines.schedule(Duration.ofSeconds(2), "poll-printer")
}
// in the adapter
@CommandHandler
@IdempotentHandler(key = "'poll:' + message.jobId + ':' + message.attempt")
fun poll(cmd: PollPrintJob) {
    val job = printer.status(cmd.jobId) ?: return
    if (job.done) events.publishBlocking(PostcardPrinted(job.jobId, job.name), key = job.name)    // the saga ends on this event
}
```

Give every waiting saga a timeout deadline of its own, so an answer that never comes ends it: the postcard saga does.

## Testing a saga

`SagaTestFixture` (in `snodra-messaging-test`, `testImplementation`) drives one saga with events and time, in memory: no Kafka,
no MongoDB, no Spring context. It runs the library's own saga runtime over in-memory storage, so a saga that passes behaves the
same on MongoDB; every step encodes and decodes the saga state as JSON, so state the codec cannot carry fails the test.

```kotlin
class PaymentSagaTest {
    private val t0 = Instant.parse("2026-11-03T10:00:00Z")

    @Test
    fun `a charge that never succeeds is cancelled when the deadline falls due`() {
        SagaTestFixture(PaymentSaga::class)                             // beans a handler asks for go after the class: SagaTestFixture(PaymentSaga::class, someBean)
            .givenCurrentTime(t0)
            .whenEvent(OrderPlaced("o1", 42))
            .expectActiveSagas(1)
            .expectAssociation("paymentRef", "pay-o1")
            .expectDispatchedCommands(RequestCharge("pay-o1", 42))
            .expectScheduledDeadline("charge-timeout", t0.plus(Duration.ofMinutes(15)))
            .whenTimeElapses(Duration.ofMinutes(15))
            .expectDispatchedCommands(RequestCharge("pay-o1", 42), CancelCharge("pay-o1"))   // everything sent since the last given…
            .expectSagaEnded()
    }

    @Test
    fun `a command that failed for good ends the saga and says so`() {
        SagaTestFixture(PaymentSaga::class)
            .whenEvent(OrderPlaced("o2", 10))
            .whenCommandFailed(RequestCharge("pay-o2", 10), SagaCommandFailed.Reason.UNKNOWN_OUTCOME, "gateway crashed")
            .expectPublishedEvents(OrderPaymentFailed("o2", "UNKNOWN_OUTCOME"))
            .expectNoScheduledDeadlines()
            .expectSagaEnded()
    }
}
```

Steps: `givenEvents(...)`, `givenCurrentTime(instant)`, `whenEvent(event, headers = emptyMap())`,
`whenCommandFailed(command, reason, message = "")` (delivers the `SagaCommandFailed` the relay would for a command the saga sent),
`whenTimeElapses(duration)` (fires every deadline that falls due on the way, each at its own due time, so a polling deadline fires
once per interval). Expectations: `expectActiveSagas(n)`, `expectAssociation(key, value)`, `expectDispatchedCommands(...)`,
`expectPublishedEvents(...)`, `expectScheduledDeadline(name, at)`, `expectNoScheduledDeadlines()`, `expectSagaEnded()`. The dispatch
expectations cover what was sent since the last `given…` step, in order. A handler that throws fails the step with an
`IllegalStateException`; a failed expectation is an `AssertionError`. The adapter and the controller are tested the usual way (an
adapter against a fake of the partner, the controller with a mock request and a computed signature, which
`WebhookSignatureVerifier.hmacHex(secret, body)` gives you); the example has both.

## Operating sagas

- **A parked event.** An event whose saga handler failed all its attempts is written to `saga_failures` (with its marker, so the
  consumer moves on), counted in `snodra.saga.events{outcome="parked"}` and logged at error. Inject `SagaFailures` and call
  `list(type?)`, `retry(id)`, `retryAll(type)` or `discard(id)` once the cause is fixed. Nothing retries a parked event by itself.
- **Metrics** (Micrometer, with a `MeterRegistry` bean in a service that uses sagas or idempotent handlers): `snodra.sagas.started`,
  `snodra.sagas.ended`, `snodra.sagas.active`, `snodra.saga.events{type,outcome}` (`handled`, `no_match`, `conflict`, `parked`),
  `snodra.saga.dispatch.pending`, `snodra.saga.command.failures`, `snodra.deadlines.fired`, `snodra.deadlines.due`,
  `snodra.external.calls{handler,outcome}`. A `no_match` count that grows means an association that does not line up. Logs carry
  `sagaType`, `sagaId` and `correlationId` in the MDC while a saga handles a message.
- **Deadlines** fire at least once, after their due time, from any instance of the service (a lease makes each fire on one), also
  after a restart, and never for a cancelled deadline or an ended saga.
- Configuration: the `sagas.*`, `deadlines.*` and `external.*` rows of the [configuration table](configuration.md#configuration).

## Gotchas

- **The translator bean carries the source's name** (`@Component("printer")` or a `@Bean` method named `printer`). A source with
  no such bean fails the startup naming it. For the same reason do not name another bean `printer` (the example's client bean is
  called `printerClient`).
- **Partner topics are not created by the library**, and the sandbox's Kafka does not auto-create topics: create the partner's
  topic first (the examples have a one-shot `printer-topic-init` for `printer.events`).
- **Use the library's `JsonCodec` bean** to read a webhook body or a partner record. It is the codec that writes your messages and
  your saga's state, with the same conventions; an `ObjectMapper` of your own may read the same JSON differently.
- **A saga only sees events consumed after it is deployed.** There is no replay of past events into a new saga type.
- **Ordinary `@EventHandler`s run first, and a failing one does not hide the event from the sagas.** The saga stage runs even
  when an ordinary handler failed, and the failure is then thrown, so the consumer retries and then dead-letters the record by its
  mode ([Dead letters](#dead-letters)); the sagas have applied the event once by then (their own markers make the redeliveries safe).
- **A step that must not run after the step before it failed** is sent from the handler of the event that says the previous step
  succeeded, not recorded in the same handling: the relay sends a saga's later steps after a permanently failed one.
- **Leases need synchronised clocks.** The relay, deadline and `external_calls` leases are timestamps compared across instances;
  keep the clocks in step (NTP).
- **A partner that recreates its topic needs a `dedupeKey`.** Without one the dedupe id is `<name>:<partition>:<offset>`; a recreated
  topic starts again at offset 0 and its records collide with the markers of the old ones for up to `idempotency.retention` (30
  days) and are skipped silently.
- **A saga sends through `SagaCommands` only.** A handler parameter of type `CommandBus`, `QueryBus`, `EventBus`, `RawCommandSender`,
  `RawEventPublisher` or `HubBus` (or a subclass or implementation of one) fails the startup: it would send at once, outside the
  saga's transaction, with no relay ordering, retry or idempotency key.
- **Saga commands have no caller.** A target with `@RequiresAuthentication` refuses them (`DENIED`).
- **Handlers of one event type run in method-name order**, not declaration order: name them so that order is the one you want.
- **Saga state is JSON.** Use `var` properties with defaults (or nullable ones) and types the library's codec can write; the
  startup check round-trips a fresh instance. Do not keep a Spring bean or a client in a saga: take it as a handler parameter.
- **At most 999 messages** can be sent or published by one handling.
- **A saga is for one service.** To talk to another service send it a command or publish an event; a saga never reads another
  service's database.

## Event processors

Every `@EventHandler` belongs to an **event processor** (P6a, ADR 0022). A processor is its own Kafka
consumer, in its own consumer group, on the events topic: its own position, its own failure domain, its own idempotency markers
and dead letters. A slow projection in one processor never holds a notifier in another.

```kotlin
@Component
@ProcessingGroup("orders")              // every @EventHandler of this class runs in processor "orders"
class OrdersProjection(private val orders: OrderRepository) {
    @EventHandler fun on(event: OrderPlaced) = orders.insert(event.toRow())
    @EventHandler fun on(event: OrderShipped) = orders.markShipped(event.orderId)
}

@Component
class Notifier {                         // no annotation: processor "default"
    @EventHandler fun on(event: OrderPlaced) = mail.confirm(event)
}
```

- **Names.** `@ProcessingGroup("name")` on a handler class; the name matches `^[a-z0-9][a-z0-9-]{0,47}$` and is not `default`. A
  bad name fails the startup naming the handler. Classes without the annotation are in processor `default`. Command and query
  handlers of an annotated class are not affected.
- **Groups.** Every processor, `default` included, uses `<service group>.<name>`, the service group being
  `snodra.messaging.kafka.group-id`, else the service name (`orders-service.default`, `orders-service.orders`), so a processor
  starts from the earliest offset the first time it runs.
- **Markers.** Every processor, `default` included, writes `processor:<name>:<eventId>` in `processed_events`, so one event type
  handled in two processors is handled by both, each exactly once. A marker a processor writes for a Kafka record also carries
  `processor`, `topic`, `partition` (Int32) and `offset` (Int64): a reset deletes exactly the markers of its replay range
  ([Processor control](#processor-control)).
- **Sagas run only in `default`** (their stage 2 follows the default processor's stage 1). A named processor runs
  only its handlers.
- **Which processors start.** At startup, one consumer per processor that has a handler; `default` also when sagas run. A
  service with no `@EventHandler` and no saga starts no consumer.
- **Attempts and back-off** (`kafka.consumer.max-attempts`, 1 s between attempts) are shared by all processors.
- **External sources and webhooks** dispatch locally to the handlers of every processor, each in its own transaction under its
  own marker (`processor:<name>:<dedupeId>`), and to the sagas once. Their records are never dead-lettered. The source names
  `processor`, `saga`, `ingress` and `failed` are refused (a partner source at startup, a webhook at the call): their markers
  would collide with the library's own.

**Moving an existing handler into a named processor runs it again over the whole topic.** The named processor's group is new,
so it starts at the earliest offset the topic still holds, and its markers (`processor:<name>:<eventId>`) are a new family,
so none of those records is a duplicate to it: the handler runs once more for every event in the topic's retention. A
projection that rebuilds idempotently may want exactly that; a handler with effects outside MongoDB (an email, a payment
call) repeats every one of them. For such code either leave the handler where it is and put only new handlers in the named
processor, or commit the new group's offsets at the end of the topic before you deploy it:
`kafka-consumer-groups --bootstrap-server <broker> --group <group>.<name> --topic <events topic> --reset-offsets --to-latest --execute`
(`<group>` is `snodra.messaging.kafka.group-id` or the service name; the group must have no running member). Records produced
between that reset and the moment the old instances stop are handled twice, once by the old `default` and once by the new
processor, so reset right before the rollout. Once it runs, a reset to `latest` through the hub does the same without a shell
([Processor control](#processor-control)), but by then it has already run once over the topic.

**Status at the hub.** Every status report (`hub.status-interval`, 5 s) carries one `ProcessorStatus` per started processor to
every hub: name, group,
topic, state, the partitions assigned to this instance with position, committed offset, high watermark and lag, records processed
and failed since start, the dead-letter count, the last error (message only, never a payload), the event types and the
dead-letter mode. The hub shows them in `GET /api/v1/topology`, `GET /api/v1/processors` and the dashboard's Processors page. The states:

| State | When |
|---|---|
| `STARTING` | started, no assignment yet (an assignment of zero partitions counts: an idle group member is `RUNNING`), or between a revocation and the next assignment |
| `RUNNING` | otherwise |
| `FAILING` | for 60 s after a record exhausted its attempts, or a record could not be acknowledged (its letter could not be parked, the DLT could not be reached); wins over `STARTING` and `RUNNING` |
| `PAUSED` | paused through processor control (P6b): still in its group, consuming nothing; wins over `FAILING`, `STARTING` and `RUNNING` |
| `STOPPED` | the processor is stopping or stopped; also while a reset holds its lock (P6b), with `operation_id` set |

A report also carries `operation_id` (the reset holding the processor's lock, empty when none), `replaying` (a replay
range is open on this instance's partitions) and per partition `replay_until` (the end of its open replay range, 0 when none).

The report is built from memory and never waits: the assignment comes from the rebalance listener, the position from the last
acknowledged record (`-1` until one), the committed offsets and high watermarks from one Kafka `Admin` client (same connection
settings as the consumers) refreshed at most every 5 s on a background thread, and the dead-letter count from
`countDocuments({processor})` every 30 s and after a park. Lag is `high watermark - committed` (`- position` without a commit),
`-1` when unknown, never negative. `EventProcessors.processorStatuses()` (bean `ProcessorStatusSource`) gives the same list to an
application that wants it.

## Dead letters

A record a processor cannot handle is not only logged: by default (`snodra.messaging.kafka.dead-letter.mode: collection`)
it is **parked** in the service's MongoDB collection `dead_letters`, the later records of the same Kafka key wait behind it, and an
operator retries or discards it through the `DeadLetters` bean.

| Reason | What happened | Blocks its key | Retry |
|---|---|---|---|
| `HANDLER_FAILED` | stage 1 failed on every attempt (once for a payload the handler cannot decode, `InvalidMessageException`) | yes | yes |
| `SEQUENCED` | an earlier letter of its key is parked in this processor: stage 1 did not run (**the sagas still saw it** in `default`) | yes | yes |
| `INVALID` | no `type` header, or a value that is not a JSON object | no | no (discard) |

A type the processor does not handle is skipped, not a letter. A record without a key is never sequenced. A record that
only failed in the saga stage (stage 1 done, the saga store down on every attempt) is logged and skipped: stage 1 has nothing to
retry, and parked saga events have their own `saga_failures`.

**Never lost, parked once.** The letter is a single insert outside any transaction after the last attempt, `_id`
`<processor>:<topic>:<partition>:<offset>`; the offset is acknowledged only once the letter exists. When MongoDB is down the record
stays unacknowledged and is redelivered every second until the letter is written (the redelivery parks it, it does not run the
handler again; after a rebalance the new owner may run it once more, which stage 1's marker makes harmless). A redelivery of a record
already parked (a crash before the commit) finds its own letter and is acknowledged.

**Sequencing.** Each processor keeps the keys of its letters on its assigned partitions in memory (loaded on assignment, added to
on every park). A record whose key is in that set is checked against the collection: when the key still has a head letter (the
lowest offset that is not `INVALID`), the record is parked `SEQUENCED`; otherwise (retried, discarded or expired, possibly on
another instance) the key is forgotten and the record handled. **A letter that expires** (`dead-letter.retention`, 30 days)
**unblocks its key.**

```kotlin
@RestController
class DeadLetterAdmin(private val deadLetters: DeadLetters) {
    @GetMapping("/admin/dead-letters") fun list(@RequestParam processor: String?) = deadLetters.list(processor, limit = 100)
    @PostMapping("/admin/dead-letters/{id}/retry") fun retry(@PathVariable id: String) = deadLetters.retry(id).toString()
    @PostMapping("/admin/dead-letters/retry-all") fun retryAll(@RequestParam processor: String) = deadLetters.retryAll(processor)
    @DeleteMapping("/admin/dead-letters/{id}") fun discard(@PathVariable id: String) = deadLetters.discard(id)
}
```

`DeadLetters` (blocking; call it from a request thread):

| Call | Result |
|---|---|
| `list(processor: String? = null, limit: Int = 100): List<DeadLetter>` | sorted by `parkedAt`, then `_id` |
| `get(id): DeadLetter?`, `count(processor: String? = null): Long` | |
| `retry(id): RetryResult` | `Retried`, `Duplicate` (stage 1 had run: the letter is deleted), `Failed(message)` (the letter stays with `attempts + 1`, the new `error`, `lastAttemptAt`, reason `HANDLER_FAILED`), `Blocked(headId)` (retry the key's head first), `NotRetriable` (`INVALID`), `NotFound` |
| `retryAll(processor): RetryAllResult(retried, failed, blocked, skipped)` | per key in offset order, a key stopping at its first failure (its later letters count as blocked); then the keyless letters; `INVALID` letters skipped |
| `discard(id): Boolean` | deletes the letter; discarding a key's head makes the next letter of the key retriable |

A retry runs the processor's stage 1 (all its handlers for the type) once, **in the marker transaction, together with the letter's
deletion**: handled and deleted commit together or not at all, so a retry is exactly-once with respect to stage 1, also when two
instances retry the same letter. The sagas are not run again. A key stays blocked for new records until all its letters are retried
or discarded. Any instance of the service can serve the calls for the processors it runs; a processor it does not run (or a letter
of one) is an `IllegalArgumentException` naming it. In modes `topic` and `log` every call is an `IllegalStateException` naming the
mode.

**Mode `topic`** produces the failed or `INVALID` record to `<topic>.dlt` (same key, value and headers, plus `snodra-dlt-processor`,
`snodra-dlt-reason`, `snodra-dlt-error`, `snodra-dlt-original-topic`, `-partition` and `-offset`) and acknowledges it only after the
broker did. Nothing is sequenced and there is no admin API: the topic belongs to your tooling. **The DLT must exist, or broker
auto-creation must be on.** **Mode `log`** logs (never the payload) and skips: nothing is parked.

The document (the same from the Rust library; no `_class`, an absent field is absent):

| Field | Type | |
|---|---|---|
| `_id` | string | `<processor>:<topic>:<partition>:<offset>` |
| `processor`, `topic` | string | |
| `partition` / `offset` | Int32 / Int64 | |
| `key` | string | absent without a key |
| `eventId`, `eventType` | string | the `id` and `type` headers, absent when missing |
| `headers` | document | every record header (lossy UTF-8; a repeated name keeps its last value) |
| `payload` / `payloadBinary` | string / BinData | the value as text when it is UTF-8, else binary; both absent for an empty value |
| `reason` | string | `HANDLER_FAILED`, `SEQUENCED`, `INVALID` |
| `error` | `{type, message}` | exception simple name and message (at most 2000 characters); `Sequenced` / `InvalidMessage` |
| `blockedBy` | string | `SEQUENCED` only: the head letter when it was parked |
| `attempts` | Int32 | handler attempts so far |
| `parkedAt`, `lastAttemptAt`, `expireAt` | Date | `expireAt = parkedAt + retention` (TTL index) |
| `replay` | bool | `true` when parked while its processor replayed the record (P6b): its retry is a replay too; absent otherwise |

Indexes: `dead_letters_processor_key_offset`, `dead_letters_processor_parked`, `dead_letters_expire` (TTL), created at startup.

## Processor control

The hub (ADR 0023) pauses, resumes and resets a processor of a service **on every
instance**, and lists, retries and discards its dead letters, from its dashboard or HTTP API (writes need the hub's write token
or an ACL credential with `control = true`; see the hub's documentation). The hub keeps nothing: the state of each processor is a
document in the service's own MongoDB, `processor_control`, which every instance reads at start (before its consumers poll) and
every 5 s, so a pause outlives every hub and restart and reaches instances that start later. A `ControlRequest` is only the fast
path. The bean `ProcessorControl` does all of it; its `pause(processor)` and `resume(processor)` do the same from your own code
(`pausedBy: "local"`).

- **Pause** stops consuming every assigned partition **without leaving the consumer group** (no rebalance): the record in hand
  finishes, nothing else starts, partitions assigned later start paused. The status says `PAUSED`. **Resume** undoes it. A pause
  holds only Kafka consumption: the local dispatch of external sources, webhooks and saga notices still runs the processor's
  handlers, and the `DeadLetters` admin calls keep working.
- **Reset** moves the processor's consumer group to `earliest`, `latest`, a timestamp or explicit offsets per partition, as a
  **leased operation**: every instance is prepared (it takes the processor's lock in `processor_control` for a 30 s lease, the hub
  renews it every 10 s, and leaves the group: `STOPPED` with the operation id), one executes, every one is finished (it releases
  the lock and consumes again, still paused if it was). An instance whose lease passes without a renewal (the hub died) releases it
  and resumes by itself; an instance that starts while the lock is held stays out of the group until it clears. A second reset
  while one holds the lock is refused (`LOCKED`). A renewal that arrives after the finish never takes the lock again: an
  operation that ended on an instance (finished, aborted, its lease passed, its lock lost) is remembered for at least
  max(2 x lease, 60 s), and a prepare of it, or a renewal whose lock is gone, is refused `NOT_PREPARED`.
- **The execute** resolves the target per partition (Kafka `Admin.listOffsets`; a timestamp past the last record means the end),
  reads the group's committed offsets ("before"), refuses while the group has any active member (`GROUP_NOT_EMPTY`, nothing
  changed), runs the processor's `@ResetHandler`s, deletes the processor's markers in the replay ranges, writes the ranges to the
  document and only then commits the target offsets (`Admin.alterConsumerGroupOffsets`). Right after the reset handlers and
  again before the commit, the executor must still extend its lease (and be within 120 s): otherwise it stops with `FAILED`
  "lease lost: ...", before touching markers or offsets. **A refusal after the reset handlers ran is not "nothing changed"**:
  their effects stay, and the message says what else happened, e.g. `reset handlers ran (2), 37 markers deleted, offsets not
  moved: retry the reset`. Retry the reset (the handlers run again), or check the projection.
- **A reset to anything but `latest` is a replay**: per partition, the records from the target up to where the group was
  (`[target, before)`) are handled again, by whichever instance owns the partition, exactly once overall (their markers were
  deleted). In the range **the sagas never run** (stage 2 is skipped) and **handlers marked `@DisallowReplay` do not run**; past
  the range everything is as usual. Once an instance has consumed past the end of a range it removes the range; the status shows
  `replaying` until then. A reset does not touch the processor's dead letters. A record parked while it was replayed keeps that
  in its letter (`replay: true`), so its retry runs stage 1 as a replay too: without its `@DisallowReplay` handlers.

```kotlin
@Component
@ProcessingGroup("orders")
class OrdersProjection(private val orders: OrderRepository) {
    @EventHandler fun on(event: OrderPlaced) = orders.insert(event.toRow())

    // Once per reset that replays something, on the instance that executes it, before any marker or offset changes.
    // Throwing (an Error too) fails the reset (RESET_HANDLER_FAILED) before any marker or offset changes; what the handlers
    // that ran did stays, and the refusal says how many ran. No parameter, or a ResetContext.
    @ResetHandler fun clear(ctx: ResetContext) {
        if (ctx.target == ResetTarget.Earliest) orders.deleteAll() // the whole topic replays: rebuild from scratch
    }
}

@Component
@ProcessingGroup("orders")
class OrderMails(private val mail: Mail) {
    @DisallowReplay                      // or on the class: a replay never sends these again
    @EventHandler fun on(event: OrderPlaced) = mail.confirm(event)
}
```

`ResetContext(processor, operationId, target, ranges)`: `target` is `ResetTarget.Earliest`, `Latest`, `Timestamp(timestampMs)` or
`Offsets(map of partition to offset)`; `ranges` the `ReplayRange(topic, partition, from, until)` the reset replays (never empty: a
reset that replays nothing runs no reset handler). A `@ResetHandler` belongs to its class's processor (`@ProcessingGroup`, else
`default`) and may suspend.

The `processor_control` document (the same from the Rust library; every field is always written):

| Field | Type | |
|---|---|---|
| `_id` | string | the processor name |
| `paused` | bool | |
| `pausedAt`, `pausedBy` | Date, string | null when not paused; `pausedBy` is the hub's control id, or `local` |
| `operation` | `{id, kind: "reset", leaseUntil, preparedAt}` | the reset holding the lock, null when none; expired once `leaseUntil` passed |
| `replay` | array of `{topic, partition: Int32, from: Int64, until: Int64}` | the open replay ranges, `[]` when none |
| `updatedAt` | Date | |

Every control request is logged at INFO with its control id, processor, action and result. Requests run off the hub stream, one
at a time per processor (a renewal of the lease this instance holds is answered at once, and the instance executing a reset
extends its own lease while it runs). Dead letters through the hub map to `DeadLetters` one to one (`list` without payloads or
headers, `retry`, `retryAll`, `discard`); an instance answers only for the processors it runs and only in mode `collection`.

## Facades

```kotlin
interface EventBus {
    suspend fun publish(event: Event, key: String? = null)
    fun publishBlocking(event: Event, key: String? = null)   // default method
}

interface CommandBus {
    suspend fun <R> send(command: Command<R>, routingKey: String? = null): R
    suspend fun <R> send(command: Command<R>, options: SendOptions): R          // default method
    fun <R> sendBlocking(command: Command<R>, routingKey: String? = null): R    // default method
    fun <R> sendBlocking(command: Command<R>, options: SendOptions): R          // default method
}

interface QueryBus {
    suspend fun <R> send(query: Query<R>): R
    suspend fun <R> send(query: Query<R>, options: SendOptions): R              // default method
    fun <R> sendBlocking(query: Query<R>): R                                    // default method
    fun <R> sendBlocking(query: Query<R>, options: SendOptions): R              // default method
    suspend fun <R> scatterGather(query: Query<R>, options: ScatterOptions = ScatterOptions()): ScatterResult<R>
    fun <R> scatterGatherFlow(query: Query<R>, options: ScatterOptions = ScatterOptions()): Flow<ScatterPart<R>>
    fun <R> stream(query: StreamingQuery<R>, options: StreamOptions = StreamOptions()): Flow<R>
    suspend fun <I, U> subscribe(query: SubscriptionQuery<I, U>, options: SubscriptionOptions = SubscriptionOptions()): SubscriptionResult<I, U>
}                                            // scatter-gather: see "Scatter-gather and shared query types";
                                             // stream: see "Streaming queries"; subscribe: see "Subscription queries"

data class SendOptions(                      // every field null = the configured default
    val priority: Int? = null,               // Request.priority; default hub.priorities.<type>, else 0
    val timeout: Duration? = null,           // the caller's deadline; with retry the total budget; 0 = unset
    val routingKey: String? = null,          // commands only
    val retry: RetryPolicy? = null,          // RetryPolicy.NONE disables a configured policy
)
```

## Send options, priority and retry

- **Priority** (`SendOptions.priority`, default per type from `snodra.messaging.hub.priorities.<type>`,
  else 0) only matters when the hub queues requests for a busy, flow-controlled handler: higher
  first, equal priorities keep arrival order (ADR 0014).
  Old hubs ignore it. Local handlers (same instance) ignore it.
- **Retry** is opt-in (`snodra.messaging.hub.retry.enabled=false`; per call `SendOptions.retry`). One
  classification decides what may be retried, used by the buses
  (`RetryClassification.isRetryable(kind, error)` in Kotlin, `retry::is_retryable(kind, &err)` in Rust; the saga relay has its own
  table, because its commands carry an idempotency key, see [Command failures](../index.md#command-failures)):

  | Error | Command | Query |
  |---|---|---|
  | `HubUnavailableException` (never written) | retry | retry |
  | `NoHandlerException` (`NO_HANDLER`) | retry | retry |
  | `HandlerBusyException` (`RESOURCE_EXHAUSTED`, rejected before any handler ran) | retry | retry |
  | `HandlerDisconnectedException`, `MessageTimeoutException`, `HubConnectionLostException` | **never** (the command may have run) | retry |
  | anything else (handler errors, authentication, authorization, invalid messages) | never | never |

  Every attempt is a new hub request (fresh `Request.id`, same correlation id). All attempts share
  one budget: the caller's timeout (`SendOptions.timeout` or `request-timeout`), else the hub's
  bound for the type from its `RegisterAck` (per-type override, else its default; 5 s before any
  ack). While retrying, each attempt sends the remaining budget as `timeout_ms` (never less
  than 1 ms). Waits are 100 ms doubling to 2 s by default, each with ±20 % jitter (never above the
  maximum). A retry starts only if at least `max(initial-backoff, 250 ms)` of the budget is left once
  its wait is over (`RetryPolicy.MIN_ATTEMPT_BUDGET`); otherwise the last error is thrown at once,
  so no attempt goes out with a deadline too short to succeed. Any `RetryPolicy` object is in force as written (`maxAttempts = 1`,
  `RetryPolicy.NONE`, means no retry); zero attempts is rejected. Local handlers are never retried.
- **Rust:** the same rules. `SendOptions { routing_key, timeout, authorization, priority, retry }`, all
  `Option` (`SendOptions::default()` keeps the configured defaults; a zero `timeout` counts as unset);
  a `RetryPolicy` is in force as written (`RetryPolicy::default()` is 3 attempts, 100 ms, ×2, 2 s;
  `RetryPolicy::NONE`, one attempt, switches a configured policy off for one call); a per-call policy
  with zero attempts fails the send with `InvalidMessage` before anything is written. The 250 ms
  floor is `hub::RETRY_MIN_REMAINING`. The table's rows are `MessagingError::HubUnavailable`, `NoHandler`,
  `HandlerBusy` (both kinds) and `HandlerDisconnected`, `Timeout`, `HubConnectionLost` (queries only);
  `RemoteHandler` "handler busy" is not retried either. The crate has no local short-circuit, so
  every send goes through the hub (and may be queued and retried).


`EventBus.publish` does not talk to Kafka directly. Inside a Mongo transaction it writes an
`outbox` document; outside a transaction it writes the `outbox` document in its own transaction. The
`OutboxPublisher` (below) moves it to Kafka. This keeps the "publish" call cheap and atomic with the
domain write.

`CommandBus.send` and `QueryBus.send` resolve the handler locally first (local short-circuit); when
the current service has a handler for the type, it is invoked in-process with the same semantics and
no hub round trip. Otherwise the message goes to the hub.

## Annotations

```kotlin
@Target(AnnotationTarget.FUNCTION) annotation class EventHandler
@Target(AnnotationTarget.FUNCTION) annotation class CommandHandler
@Target(AnnotationTarget.FUNCTION) annotation class QueryHandler(val shared: Boolean = false) // shared: ADR 0017

@Target(AnnotationTarget.CLASS) annotation class MessageType(val value: String)
```

Handler methods are ordinary methods on Spring beans. The single parameter is the message; an
optional second parameter of type `MessageContext` gives access to headers, the acting user and the
correlation id. Command and query handlers return the response object (or `Unit`, serialised as
`{}`). Handlers may be `suspend`.

`@MessageType` is defined in the dependency-free artifact `com.damoreira.snodra:snodra-messaging-api`, which `*-api` modules depend on so they never pull in Spring, Kafka or gRPC (see 04-repositories.md).

```kotlin
@MessageType("billing.LogWorkout")
data class LogWorkout(val workoutId: String, val exercises: List<ExerciseEntry>)

@MessageType("billing.WorkoutLogged")
data class WorkoutLogged(val workoutId: String, val userId: String, val loggedAt: Instant)

@Component
class WorkoutHandlers(private val repo: WorkoutRepository, private val events: EventBus) {

    @CommandHandler
    @Transactional
    suspend fun handle(cmd: LogWorkout, ctx: MessageContext): LogWorkoutResult {
        val workout = repo.save(Workout.from(cmd, ownerId = ctx.userId))
        events.publish(WorkoutLogged(workout.id, workout.ownerId, workout.loggedAt), key = workout.id)
        return LogWorkoutResult(workout.id)
    }

    @QueryHandler
    suspend fun handle(q: GetWorkout): GetWorkoutResult =
        repo.findById(q.workoutId)?.toResult() ?: throw NotFoundException(q.workoutId)

    @EventHandler
    suspend fun on(e: FileDeleted) {
        repo.detachFile(e.fileId)
    }
}
```

Sending from a REST controller:

```kotlin
@RestController
class WorkoutController(private val commands: CommandBus, private val queries: QueryBus) {

    @PostMapping("/workouts")
    suspend fun log(@RequestBody body: LogWorkout): LogWorkoutResult =
        commands.send(body, routingKey = body.workoutId)

    @GetMapping("/workouts/{id}/attachments/{fileId}")
    suspend fun attachment(@PathVariable fileId: String): GetFileMetadataResult =
        queries.send(GetFileMetadata(fileId))   // handled by another service through the hub
}
```

## Handler discovery and registration

A `BeanPostProcessor` scans every bean for annotated methods at startup, reads the parameter type,
resolves its wire type name, and builds three registries (event, command, query). Then:

- event types feed the Kafka consumer filter;
- command and query types are sent to the hub in the `Register` message;
- duplicate command or query handlers for the same type in one service fail startup.

Adding a handler after startup (for example in tests) re-sends `Register`.

## Several hubs

With more than one hub (ADR 0016,
[hub.md](../../server/index.md)) both libraries open one stream per hub with the
identical `Register` (two targets answering the same `hub_id` are one hub). A request without a
routing key goes round-robin over the live hubs; a keyed one goes to the live hub with the highest
rendezvous score `fmix64(fnv1a64(utf8(hub_id) ++ 0x00 ++ utf8(key)))`, compared unsigned (64-bit
FNV-1a, MurmurHash3's finalizer; vector `("hub-1", "order-42")` -> `0x5c855509f5ad7c8d`), so a key
keeps its hub while the hubs are stable. A request that could not be written goes to another hub;
one already written fails with `HubConnectionLostException` when its stream drops (what counts as
written may differ between the libraries, see each README). The whole call keeps one deadline, its
own timeout: waiting for a live hub ends there with `HubUnavailableException`, and a request sent
again carries what is left of its `timeout_ms`. Each stream announces
`ceil(max-concurrent-handlers / N)` permits, N = the hub being registered on plus the other hubs
that are live or still on their first connect attempt (a failed first attempt counts as gone).
When N shrinks, every live stream gets a top-up
`Permits{count = max(0, ceil(max / N) - offered), grant = ceil(max / N)}`, offered = its
`initial_permits` plus earlier top-ups (so flaps never add up); the grant raises the hub's permit
cap on the session (otherwise its `initial_permits`) so the hub keeps the top-up; a hub that
joins or returns gets `ceil(max / N)` on its new stream; nothing is ever revoked, and locally at most
`max-concurrent-handlers` handlers run in total. A `dns:///` answer is used in one address family:
its IPv4 addresses when it has any, else its IPv6 ones, without repeats (a dual-stack name lists
each hub twice, and the hub keeps one session per instance id). The first target to acknowledge a
`hub_id` keeps it while it is kept; a later one answering the same id is parked, never takes over.
An ack with an empty `hub_id` is identified by its target id: the bare `host:port` (no
`static://`; a resolved IPv6 address as `[ip]:port` without zone).
`HubConnections.awaitRegistered` (Kotlin) is true only once every kept hub confirmed the
registration.

**Breaking (Kotlin):** the `snodraHubChannelFactory` override bean is now a
`com.damoreira.snodra.messaging.hub.HubChannelFactory` (`target -> ManagedChannel`, called once per
connection attempt to each hub) instead of a `() -> ManagedChannel`, and the exposed bean is
`HubConnections` (one `HubConnection` per hub; `awaitRegistered`, `connections()`) instead of
`HubConnection`. Tests that read `HubConnection` from the context must switch to `HubConnections`.
The version stays `0.1.0-SNAPSHOT` (nothing was published beyond local `mavenLocal()` installs);
re-run `./gradlew publishToMavenLocal` in snodra-messaging before rebuilding a service.

## Error types

| Exception (Kotlin) | Cause |
|---|---|
| `NoHandlerException` | hub `Error{code=NO_HANDLER}`: nobody registered the type |
| `MessageTimeoutException` | hub `Error{code=TIMEOUT}` or client-side deadline |
| `HandlerDisconnectedException` | hub `Error{code=HANDLER_DISCONNECTED}` |
| `RemoteHandlerException` | handler returned `Reply{error{code=HANDLER_ERROR}}`; carries `message` and `details` |
| `UnauthenticatedException` | handler requires authentication and the request carried no identity, or the forwarded JWT failed validation (`UNAUTHENTICATED`); or the hub's token left its ACL while the stream was open (an immediate hub `Error`) |
| `AccessDeniedException` | `PERMISSION_DENIED`: a handler's `@RequiresAuthentication` expression denied an authenticated caller, or the hub's access control refused a `send`/`stream`/`subscribe`/`scatterGather` because the type is outside the token's `send` patterns (an immediate hub `Error`, before anything is routed). Never retried |
| `HubRegistrationRejectedException` | thrown by `awaitRegistered` when the hub closed the stream and refuses this registration: `ALREADY_EXISTS` (a type or service another registrant owns), `INVALID_ARGUMENT`, `UNAUTHENTICATED` (no or unknown token) or `PERMISSION_DENIED` (service name or handled type outside the token's ACL entry). The message names the code and the hub's reason; the connection keeps retrying at the backoff cap and the rejection is in `lastRejection` |
| `InvalidMessageException` | payload did not deserialise on the handler side (`INVALID_REQUEST`) |
| `HubUnavailableException` | the request was **never written** to a live hub stream: no stream came up within the wait, or the stream closed before the write. Safe to retry |
| `HubConnectionLostException` | the request **was written** to a hub stream and that stream broke before an answer: outcome unknown, the handler may or may not have run. Retry like a `TIMEOUT` (idempotent commands only) |
| `StreamCancelledException` | hub `ReplyEnd{error{code=CANCELLED}}`: a streaming query outlived `SNODRA_SERVER_MAX_STREAM_DURATION`, or a subscription `SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION`; the parts emitted before it stay emitted; never retried |
| `HandlerBusyException` | `RESOURCE_EXHAUSTED`: the target instance's hub queue (or session buffer) was full; rejected before any handler ran, so retrying is safe. For a subscription query it is also the subscriber's buffer overflowing at the hub or an owner instance at its subscription limit, and the message carries the hub's or the instance's reason (constructor parameter `detail`) |

All extend `MessagingException`. Handlers signal application errors by throwing; the library maps
the exception to `HANDLER_ERROR` with the exception message and, for validation failures, `details`
as a JSON array of `"<propertyPath>: <message>"` strings.

Rust: the same causes are `MessagingError` variants of the same names without `Exception`
(`AccessDenied`, `Timeout` for `MessageTimeoutException`, `RemoteHandler { type_name, message, details }`,
`Cancelled` for `StreamCancelledException`);
`RESOURCE_EXHAUSTED` is `MessagingError::HandlerBusy(type)` ("Handler for '<type>' is busy"; the reason a hub gives for
a subscription's `RESOURCE_EXHAUSTED` is not kept, only logged at debug).

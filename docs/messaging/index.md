# The messaging model

This document specifies the messaging layer in Snodra: the Kotlin starter
`snodra-messaging`, the Rust crate `snodra-messaging-rs`, the wire format, the Kafka layout, the
outbox, and the hub protocol. 

## The model in one paragraph

There are three kinds of messages. An **event** states that something happened; it is published to
Kafka and any number of services may handle it, asynchronously. A **command** asks exactly one
service to do something and returns a response; it goes through the hub over gRPC. A **query** asks
one service for data and returns a response; it also goes through the hub (a **streaming query** is
answered as a stream of parts instead, see [Streaming queries](#streaming-queries), and a **subscription query**
as an initial result followed by pushed updates, see [Subscription queries](#subscription-queries)). A service declares what it
handles with annotated methods, and the parameter type of the method decides the routing. Message
classes live in the owning service's `*-api` module and are the schema.

## Message naming

| Rule | Example |
|---|---|
| Wire type name is `<service prefix>.<ClassName>` | `billing.WorkoutLogged` |
| Service prefixes | `orders`, `billing`, `catalog` |
| Events are past tense | `orders.OrderPlaced`, `billing.InvoiceIssued` |
| Commands are imperative | `billing.LogWorkout`, `catalog.AttachFile` |
| Queries start with `Get`, `Find` or `List` | `catalog.GetItem`, `billing.FindInvoice` |
| Responses are `<CommandOrQuery>Result` | `GetFileMetadataResult` |
| Kotlin package | `com.damoreira.snodra.<service>.api.{events,commands,queries}` |

The prefix comes from `@MessageType` (see below) or, when absent, from the library configuration
key `snodra.messaging.type-prefix` plus the simple class name.

## Scatter-gather and shared query types

Hub side and protocol: ADR 0017,
[hub.md, Query modes](../server/protocol.md#query-modes). A query type is **exclusive** (one owning
service, the default) or **shared** (any number of services may own it). A point query on a shared
type goes to one live instance of any owner (one round-robin pool over all owners at the hub); a
**scatter-gather** asks every live instance of every owner (on an exclusive type: every instance of
its one owner) and returns what they answered. Handlers need nothing new: each target receives an
ordinary unary request with the id `<id>#<n>` and answers it as usual.

**Registration.**

```kotlin
@Component
class CatalogueSearch {
    @QueryHandler(shared = true)               // every service that answers SearchEverything declares it shared
    fun handle(q: SearchEverything): SearchHits = SearchHits(index.search(q.text))
}
```

```rust
let app = SnodraMessaging::builder(config).await?
    .shared_query::<SearchEverything, _, _>(|q, _ctx| async move { Ok(SearchHits { .. }) })
    .start().await?;
```

A shared type goes into `Register.shared_query_types` instead of `query_types`. Commands are never
shared.

**The call.**

```kotlin
// suspend fun <R> scatterGather(query: Query<R>, options: ScatterOptions = ScatterOptions()): ScatterResult<R>
val result = queryBus.scatterGather(SearchEverything("legs"), ScatterOptions(timeout = Duration.ofSeconds(2)))
result.parts.forEach { p -> println("${p.service}/${p.instance}: ${p.result ?: p.error?.code}") }
// fun <R> scatterGatherFlow(query: Query<R>, options: ScatterOptions = ScatterOptions()): Flow<ScatterPart<R>>
queryBus.scatterGatherFlow(SearchEverything("legs")).collect { part -> render(part) }
```

```rust
// Sender::scatter_gather(&q, ScatterOptions) -> Result<ScatterResult<Q::Reply>, MessagingError>
let result = app.queries().scatter_gather(&SearchEverything { text }, ScatterOptions {
    timeout: Some(Duration::from_secs(2)), max_results: 0, priority: None,
}).await?;
// Sender::scatter_gather_stream(&q, ScatterOptions) -> impl Stream<Item = Result<ScatterPart<Q::Reply>, MessagingError>>
let mut parts = app.queries().scatter_gather_stream(&SearchEverything { text }, ScatterOptions::default());
```

| | Kotlin | Rust |
|---|---|---|
| Options | `ScatterOptions(timeout: Duration? = null, maxResults: Int = 0, priority: Int? = null, retry: RetryPolicy? = null)` | `ScatterOptions { timeout: Option<Duration>, max_results: u32, priority: Option<i32> }` (`Default`) |
| Result | `ScatterResult<R>(parts, failed: Int, timedOut: Int)`, plus `results` (the successful values) | `ScatterResult<R> { parts: Vec<ScatterPart<R>>, failed: u32, timed_out: u32 }` |
| Part | `ScatterPart<R>(service, instance, result: R?, error: RemoteHandlerException?)` | `ScatterPart<R> { service, instance, outcome: Result<R, RemoteError> }` |
| Part failure | `RemoteHandlerException.code`: the hub's code (`HANDLER_ERROR`, `HANDLER_DISCONNECTED`, `RESOURCE_EXHAUSTED`, ...) | `RemoteError { code, message, details }`; `into_error(type)` gives the unary error |

- **Options.** `timeout` is the deadline of the whole gather, sent as `timeout_ms` under the
  usual rules (default `request-timeout` / `Config.hub_request_timeout`, else the hub's bound;
  zero is unset). `maxResults` / `max_results > 0` ends the gather after that many successful
  parts. `priority` is the `Request.priority` of every target request (default per type, else 0).
- **Result.** One part per target that answered, successes and failures, in arrival order;
  `failed` counts the parts with an error, `timedOut` / `timed_out` the targets without an answer
  at the deadline (they have no part). **Partial answers are answers:** the call succeeds; check
  `failed + timedOut` for "all or nothing". The flow / stream carries the parts only, no counts.
- **The gather always goes through the hub**, also from a Kotlin service that owns the type (no
  local short-circuit; that instance is one of the targets).

**Errors.**

| Situation | Kotlin | Rust |
|---|---|---|
| No live target | `NoHandlerException` | `NoHandler` |
| A command type | `InvalidMessageException` | `InvalidMessage` |
| The stream to the gather's hub breaks before the end | `HubConnectionLostException` (parts received are dropped) | `HubConnectionLost` (parts received are dropped) |
| No end within the local guard | `MessageTimeoutException` | `Timeout` |

**Shared rulings (both libraries).**

1. **An undecodable part is a failed part** (code `ERROR_CODE_UNSPECIFIED` / `UNSPECIFIED`, the
   decode error as message), never a failure of the whole call; `failed` counts it.
2. **Several hubs:** a gather goes to one live hub (unkeyed round-robin).
3. **The flow / stream retries only until its first part:** after a part was emitted an error ends
   it, so no part is ever emitted twice.

**Retry.** The query rules of Send options, priority and retry
apply to the whole gather (`HubUnavailable`, `NoHandler`, `HandlerBusy`, `HandlerDisconnected`,
`Timeout`, `HubConnectionLost`), within one budget. A retry is a new gather with a fresh id,
collected from scratch: the result holds only its own parts. Kotlin takes the configured policy or
`ScatterOptions.retry`; Rust takes `Config.hub_retry` (no per-call policy on `ScatterOptions`).

**Consistency rule.** Every registrant of a type, in every service, must declare it the same way.
A type registered exclusive by one registrant and shared by another (even within one service, on
another instance) fails the later `Register` with `ALREADY_EXISTS`: Kotlin logs it and surfaces it
like any registration conflict (`HubRegistrationRejectedException` from `awaitRegistered`); Rust
keeps retrying at the backoff cap with the reason in `last_rejection`. One service declaring a type
both ways fails at startup (Kotlin: `IllegalStateException` from the handler registry; Rust: a panic
in `shared_query` / `query`). Switching a type between exclusive and shared needs every registrant
gone and the owner grace expired.

Sandbox: `examples.Inventory` is shared by service-b (Kotlin) and service-c (Rust); service-a's
`GET /inventory` (point query) and `GET /scatter/inventory` (scatter-gather) drive it, and the
examples smoke checks both (see `snodra-messaging/examples/README.md`).

## Streaming queries

Hub side and protocol: ADR 0017 (P4b),
[hub.md, Streaming](../server/protocol.md#query-modes). A **streaming query** is answered by one
instance of one owner as a stream of parts under the collector's back-pressure: an export, a long
listing, a search that trickles. Its type is exclusive or shared like any query type (a shared one
goes to one instance of any owner: one pool over all owners at the hub); the hub picks the instance
as for a point query. The query is a
`StreamingQuery` (Kotlin `StreamingQuery<R>`, Rust `StreamingQuery { type Item }`), not a `Query`:
it cannot be sent as a point query or gathered.

**Registration.**

```kotlin
@MessageType("workouts.ExportWorkouts")
data class ExportWorkouts(val ownerId: String) : StreamingQuery<WorkoutRow>

@Component
class WorkoutExport(private val repo: WorkoutRepository) {
    @QueryHandler                              // or @QueryHandler(shared = true): one instance of any owner answers
    fun handle(q: ExportWorkouts): Flow<WorkoutRow> = repo.streamByOwner(q.ownerId).map { it.toRow() }
}
```

```rust
#[derive(Serialize, Deserialize)]
struct ExportWorkouts { owner_id: String }
message_type!(ExportWorkouts, "workouts.ExportWorkouts");
impl StreamingQuery for ExportWorkouts { type Item = WorkoutRow; }

let app = SnodraMessaging::builder(config).await?
    .streaming_query::<ExportWorkouts, _, _, _>(|q, _ctx| async move { Ok(repo.stream_by_owner(q.owner_id)) })
    // .shared_streaming_query::<Search, _, _, _>(..)   // many services may own it
    .start().await?;
```

Kotlin: `@QueryHandler` (plain or `shared = true`) on a method taking the `StreamingQuery<R>`
(optionally with a `MessageContext`) and returning `Flow<R>`; another return type,
`@CommandHandler`, or a `Flow` returned for a plain `Query` fails at startup;
`@RequiresAuthentication` is checked before the flow starts. Rust: the handler is a
`Fn(Q, MessageContext) -> Future<Output = Result<S, MessagingError>>` with
`S: Stream<Item = Result<Q::Item, MessagingError>> + Send + 'static` (a `BoxStream` fits); guards
run before it; an `Err` item ends the stream with that error. On the wire a streaming type is
announced like any query type (`Register.query_types`, or `shared_query_types` when shared): the
hub does not tell a streaming type from a unary one, the mode is the sender's choice, and the
handler's library checks that the modes match (below). Rust `registered_types()` lists the
exclusive streaming types in `RegisteredTypes.streaming_queries`.

**The call.**

```kotlin
// fun <R> stream(query: StreamingQuery<R>, options: StreamOptions = StreamOptions()): Flow<R>
queryBus.stream(ExportWorkouts(ownerId), StreamOptions(initialCredit = 32, timeout = Duration.ofSeconds(30)))
    .collect { row -> writer.write(row) }
```

```rust
// Sender::stream(&q, StreamOptions) -> Result<BoxStream<'_, Result<Q::Item, MessagingError>>, MessagingError>
let mut rows = app.queries().stream(&ExportWorkouts { owner_id }, StreamOptions {
    timeout: Some(Duration::from_secs(30)), max_results: 0, priority: None, initial_credit: 32,
}).await?;                                        // returns once the first item (or the end) is in
while let Some(row) = rows.next().await { writer.write(row?); }
```

| | Kotlin | Rust |
|---|---|---|
| Options | `StreamOptions(timeout: Duration? = null, maxResults: Int = 0, priority: Int? = null, initialCredit: Int = 64, retry: RetryPolicy? = null)` (`maxResults >= 0`, `initialCredit >= 1`) | `StreamOptions { timeout: Option<Duration>, max_results: u32, priority: Option<i32>, initial_credit: u32 }` (`Default`: `initial_credit` 64; 0 reads as 64) |
| Result | `Flow<R>`: cold and unbuffered, one request per collection, the next part is read only after the collector consumed the previous one; completes when the handler's flow does | `BoxStream<'_, Result<Q::Item, MessagingError>>`: the open awaits the first item or the end, so everything before that is the call's error; an end with an error is the stream's last item |
| A part that does not decode | `InvalidMessageException` fails the flow, the stream is cancelled | `Serialization`, the handler is cancelled (items use the unary reply codec) |

- **Options.** `timeout` is the **idle** timeout: the hub ends the stream with `TIMEOUT` when no
  part arrives within it (from the forward, reset by every part, paused while the credit is
  exhausted; a queue wait at the hub is bounded by it too), sent as `timeout_ms` under the usual
  rules (default `request-timeout` /
  `Config.hub_request_timeout`, else the hub's bound). `maxResults` / `max_results > 0` ends the
  stream after that many parts: the hub sends the end and cancels the handler (the handler always
  gets `max_results = 0`). `priority` is the forwarded request's (default per type, else 0).
  `initialCredit` / `initial_credit` is the credit window, below. The hub also bounds a stream's
  whole life (`SNODRA_SERVER_MAX_STREAM_DURATION`, 10 min by default): `CANCELLED`.
- **The stream always goes through the hub**, also from a Kotlin service that owns the type (no
  local short-circuit).
- **Owned stream (Rust).** `Sender::stream` borrows the `Sender` for the stream's life;
  `Sender::stream_owned(self: &Arc<Self>, &q, StreamOptions) -> Result<BoxStream<'static,
  Result<Q::Item, MessagingError>>, MessagingError>` is the owned variant for a spawned task or an
  HTTP streaming body.

**Credits and back-pressure.** `initialCredit` / `initial_credit` is the window: the handler may
send that many parts before the collector consumed any. The handler's library sends parts only
under credit: Kotlin suspends the handler's flow inside `emit` while the hub granted no credit; Rust
pulls the handler's stream at most one item ahead of the credit and holds that item until credit
arrives (the end or a failure is sent as `ReplyEnd` as soon as the stream reports it, with or
without credit); Kotlin reads the request's `initial_credit` as unsigned. The handler waits for
credit at most `snodra.messaging.hub.stream-credit-timeout` / `Config.hub_stream_credit_timeout`
(default 10 minutes, the hub's default max stream duration), then ends the stream with `TIMEOUT "no
credit within <d>"` and releases its permit (a hub that forgot the stream would otherwise hold them
for ever). The sender's library refills: each time the consumer took `max(1, initial / 2)`
parts (consumed, not merely arrived) it sends `Flow{max(1, initial / 2)}`, so a collector that keeps up
never stalls the handler and a slow one holds it at the window (plus the held item in Rust). A slow
consumer is no idle handler: the hub's idle clock is paused while the credit is exhausted and starts
over at the `Flow` that raises it, so only `SNODRA_SERVER_MAX_STREAM_DURATION` bounds a collector that
stops consuming. The handler numbers its parts with `seq` from 1; the sender checks the continuity
(1, 2, 3 …) and `ReplyEnd.parts` against the parts it received, and a mismatch fails the stream
with `InvalidMessageException` / `MessagingError::InvalidMessage` ("stream lost N parts"). A
handler sending beyond its credit (never these libraries) ends the stream with `INVALID_REQUEST`.

**Endings and errors.** Before any part the call fails as a unary query would; an end carrying an
error fails the flow (Kotlin) or is the stream's last item (Rust), mapped **exactly like a unary
error of the same hub code**; the parts emitted before it stay emitted.

| Situation (hub code) | Kotlin | Rust |
|---|---|---|
| No owner, or no live instance listing the type (`NO_HANDLER`) | `NoHandlerException` | `NoHandler` |
| A command type, a duplicate id, a part without credit, or the wrong mode for the handler (`INVALID_REQUEST`) | `InvalidMessageException` | `InvalidMessage` |
| The handler's flow / stream failed (`HANDLER_ERROR`; `UNAUTHENTICATED` and `PERMISSION_DENIED` as for unary) | `RemoteHandlerException` (`UnauthenticatedException`, `AccessDeniedException`) | `RemoteHandler` (`Unauthenticated`, `AccessDenied`) |
| No part within the idle timeout (`TIMEOUT`), or the handler got no credit within its `stream-credit-timeout` / `hub_stream_credit_timeout` (`TIMEOUT` "no credit within ...") | `MessageTimeoutException` | `Timeout` |
| A gap in `seq`, or `ReplyEnd.parts` above the parts received (checked locally, "stream lost N parts") | `InvalidMessageException` | `InvalidMessage` |
| The handler's instance left mid-stream, also while the target was still queued (`HANDLER_DISCONNECTED`; a stream never moves to another instance) | `HandlerDisconnectedException` | `HandlerDisconnected` |
| The target's hub queue or session buffer was full (`RESOURCE_EXHAUSTED`) | `HandlerBusyException` | `HandlerBusy` |
| The stream outlived `SNODRA_SERVER_MAX_STREAM_DURATION` (`CANCELLED`) | `StreamCancelledException` (new in P4b) | `MessagingError::Cancelled` (new in P4b) |
| The stream to the hub breaks before the end | `HubConnectionLostException` | `HubConnectionLost` (a loss while the request still sat in the outbound buffer moves it to the next live hub with the same id, as a unary request) |
| No part or end within the local guard (a hub that never answers) | `MessageTimeoutException` (a `Cancel` is written) | `Timeout` (the stream is cancelled, best effort) |

The local guard is twice the hub's deadline bound plus 1 s for the first part (the hub bounds a
queue wait by the timeout and then restarts the idle clock at the forward) and the bound plus 1 s,
reset by every part, after it.

**Mode mismatch.** A type has one handler, whatever its kind, and the request's mode must match
it: a stream to a type whose handler is unary, and a unary query (or a scatter-gather target) to a
streaming handler, are answered `INVALID_REQUEST` by the handler's library ("`<type>` is a
streaming query: send it with `QueryBus.stream` / `Sender::stream` (mode STREAMING)", "... is not a
streaming query handler (it answers mode UNARY)"): the caller used the wrong mode, which no retry
fixes, unlike `NO_HANDLER` for a type the instance does not serve at all.

**Cancel.** Cancelling the collector (Kotlin: `take(n)`, a cancelled coroutine or an exception in
the collector; Rust: dropping the stream before its end, also while the open is still blocked)
sends `Cancel{<id>, reason}` to the hub, which cancels the handler (Kotlin: the handler's coroutine
is cancelled, its flow sees a `CancellationException`; Rust: the handler's stream is dropped);
nothing of the stream follows. An exception thrown by the Kotlin collector is never treated as a
transport failure: it always sends `Cancel` and never fails over to another hub. The hub cancels the
handler the same way at `maxResults`, at the idle timeout, at the max duration and when the
collector's instance disconnects (the sender's session is gone: `Cancel{<id>#1, "sender
disconnected"}`). **A hub `Cancel` cancels unary and scatter-gather handlers too** (a gather target
past `maxResults` or past the deadline; Kotlin cancels the handler's coroutine, so a handler that
must not be interrupted wraps that part in `withContext(NonCancellable)`; Rust aborts the handler
task). What a `Cancel` does not interrupt: a blocking (non-suspend) Kotlin handler runs to its end,
and so does the non-abortable section of a Rust handler; in Rust, spawn the part that must run to
its end in a task of its own, which the abort does not reach. The handler permit
(`max-concurrent-handlers` / `max_concurrent_handlers`, and the hub's) is held for the whole stream
and paid back on every completion, whichever way. When the hub stream a streaming request arrived
on is lost, its handler is cancelled as well (the hub forgot the stream with the session: it would
wait for credit for ever); a unary handler runs on with its reply dropped.

**Retry.** The query rules of Send options, priority and retry
apply **only until the first part**: an end with an error is retried like an error before any part
(`HubUnavailable`, `NoHandler`, `HandlerBusy`, `HandlerDisconnected`, `Timeout`,
`HubConnectionLost`; handler errors, `Cancelled` and `InvalidMessage` are not),
within one budget; a retried stream is a new request with a fresh id (with several hubs,
round-robin to another live one), so no part is ever emitted twice. Every attempt sends the
chosen idle timeout as `timeout_ms` (a unary retry sends the remaining budget; a stream's timeout
is an idle timeout, not a deadline): the budget bounds only the wait for a hub and the retries. After the first part nothing
is retried: the flow throws, a broken hub stream as `HubConnectionLost`. Kotlin takes the configured
policy or `StreamOptions.retry`; Rust takes `Config.hub_retry` (no per-call policy on
`StreamOptions`).

**Shared rulings (both libraries).**

1. **A mode mismatch is `INVALID_REQUEST`**, answered by the handler's library (above).
2. **Credits:** the handler sends parts only under credit (Rust holds at most one item ahead); the
   sender refills `Flow{max(1, initial / 2)}` after every `max(1, initial / 2)` parts the consumer
   took.
3. **`seq` starts at 1** on the handler's side.
4. **The local guard** is `2 x timeout + 1 s` for the first part, then `timeout + 1 s` per part
   (`timeout` being the hub's deadline bound for the request's `timeout_ms`).
5. **Cancelling or dropping the collector** sends `Cancel` to the hub and the handler is
   cancelled; **a hub `Cancel` cancels unary and gather handlers too**.
6. **Permits** are paid back on every completion of a handler, streams included.
7. **A lost hub stream cancels the streaming handlers it carried.**
8. **`timeout_ms` is the chosen idle timeout on every attempt**; the budget bounds only the hub
   wait and the retries (2026-11-01).
9. **A handler waits for credit at most `stream-credit-timeout` / `hub_stream_credit_timeout`**
   (10 min), then `TIMEOUT "no credit within <d>"` and its permit is released (2026-11-01).
10. **The sender checks `seq` continuity and `ReplyEnd.parts`**: a mismatch is
    `InvalidMessageException` / `InvalidMessage` "stream lost N parts" (2026-11-01).
11. **A Kotlin collector's exception is never a transport failure**: `Cancel`, no failover
    (2026-11-01).
12. **Rust `Sender::stream` borrows; `Sender::stream_owned` is the `'static` variant**
    (2026-11-01).
13. **Kotlin reads `initial_credit` as unsigned** (2026-11-01).
14. **A hub `Cancel` does not interrupt a blocking Kotlin handler or a Rust handler's
    non-abortable section** (Rust: spawn the critical part) (2026-11-01).
15. **Several hubs:** a stream goes to one live hub (unkeyed round-robin).

Sandbox: `examples.Rows(count, failAt)` is a shared streaming type served by service-b (Kotlin,
`@QueryHandler(shared = true)` returning `Flow<Row>`) and service-c (Rust,
`shared_streaming_query`); service-a's `GET /stream/rows?count=&credit=&maxResults=&take=&failAt=`
opens the stream with those options and returns the collected rows, and the examples smoke (steps
19, 19b, 19c) checks 1000 rows in order from each owner, a collector-side cancel that leaves
nothing in flight on either hub, and a handler failure mapped to 502 (see
`snodra-messaging/examples/README.md`).

## Subscription queries

Hub side and protocol: ADR 0017 (P4c),
[hub.md, Subscription](../server/protocol.md#query-modes). A **subscription query** is an initial
result followed by the updates every handler instance pushes, until the subscriber cancels or the
handlers complete: a screen that shows an account and refreshes when it changes, a status page. Its
type is exclusive or shared like any query type; unlike a stream, the hub asks **every** live
instance of **every** owner (the update targets), and one of them,
chosen as for a point query, also answers the initial result. The query is a `SubscriptionQuery`
(Kotlin `SubscriptionQuery<I, U>`, Rust `SubscriptionQuery { type Initial; type Update }`), not a
`Query`: it cannot be sent as a point query, gathered or streamed.

**Registration.**

```kotlin
@MessageType("accounts.WatchAccount")
data class WatchAccount(val accountId: String) : SubscriptionQuery<AccountView, AccountChanged>

@Component
class AccountWatch(private val repo: AccountRepository) {
    @QueryHandler                              // or @QueryHandler(shared = true)
    fun handle(q: WatchAccount): AccountView = repo.view(q.accountId)   // the INITIAL result
}
```

```rust
#[derive(Serialize, Deserialize)]
struct WatchAccount { account_id: String }
message_type!(WatchAccount, "accounts.WatchAccount");
impl SubscriptionQuery for WatchAccount { type Initial = AccountView; type Update = AccountChanged; }

let builder = SnodraMessaging::builder(config).await?;
let emitter = builder.emitter();                  // capture it before start(), in the code that changes the data
let app = builder
    .subscription_query::<WatchAccount, _, _>(|q, _ctx| async move { Ok(repo.view(&q.account_id).await?) })
    // .shared_subscription_query::<WatchAccount, _, _>(..)   // many services may own it
    .start().await?;
```

The handler answers **only the initial result**; the updates are pushed from wherever the data
changes, through the emitter. Kotlin: `@QueryHandler` (plain or `shared = true`) on a method taking
the `SubscriptionQuery<I, U>` (optionally with a `MessageContext`) and returning `I`; a method
returning a `Flow`, or `@CommandHandler` on a subscription query, fails at startup. Rust: the
handler is a `Fn(Q, MessageContext) -> Future<Output = Result<Q::Initial, MessagingError>>`.
`@RequiresAuthentication` (Kotlin) is checked when the subscription is registered and again on the
initial request; Rust guards run before the handler. On the wire a subscription type is announced
like any query type (`Register.query_types`, or `shared_query_types` when shared), and the hub sends
each live instance a `SUBSCRIPTION` request, on which the library only registers the
subscription (the decoded query, its request id, the hub stream it arrived on): no handler runs,
no permit is held. The initial result is a separate ordinary request (`<id>#0`, mode `UNARY`) that
the same handler answers, recognised by that id. Rust `registered_types()` lists the exclusive
subscription types in `RegisteredTypes.subscription_queries`.

**The emitter.**

```kotlin
@Service
class Accounts(private val repo: AccountRepository, private val emitter: QueryUpdateEmitter) {
    @Transactional
    fun deposit(accountId: String, amount: Money) {
        val account = repo.deposit(accountId, amount)
        // Inside the transaction: delivered after the commit, dropped on a rollback.
        emitter.emit<WatchAccount, AccountChanged>({ it.accountId == accountId }, AccountChanged(accountId, account.balance))
    }
}
```

```rust
// After the commit of the write that changed the data:
emitter.emit::<WatchAccount>(|q| q.account_id == id, &AccountChanged { .. });
emitter.complete::<WatchAccount>(|q| q.account_id == id);                         // a clean end
emitter.complete_exceptionally::<WatchAccount>(|_| true, &MessagingError::Storage("feed down".into()));
```

| | Kotlin | Rust |
|---|---|---|
| The emitter | the auto-configured bean `QueryUpdateEmitter` | `QueryUpdateEmitter` (`Clone`), from `SnodraMessagingBuilder::emitter()` or `SnodraMessaging::emitter()` |
| Update | `emit(queryType: KClass<Q>, filter: (Q) -> Boolean, update: U)` and `emit<Q, U>(filter, update)` (reified) | `emit::<Q>(filter: impl Fn(&Q) -> bool, update: &Q::Update)` |
| Clean end | `complete(queryType, filter)` / `complete<Q>(filter)` | `complete::<Q>(filter)` |
| End with an error | `completeExceptionally(queryType, filter, cause: Throwable)` / `completeExceptionally<Q>(filter, cause)` | `complete_exceptionally::<Q>(filter, error: &MessagingError)` |
| Open subscriptions | `SubscriptionRegistry.size` (the bean; every type) | `QueryUpdateEmitter::open_subscriptions()` (every type) |
| Transactions | inside an active Spring transaction every call is deferred to `afterCommit` and dropped on rollback | none to defer to: **emit after your own commit** |

Each call delivers to every open subscription of that type **on this instance** whose decoded query
passes `filter`, in call order: an update is one part (encoded with the library codec), `complete`
ends the subscription cleanly, `completeExceptionally` / `complete_exceptionally` ends it with
`HANDLER_ERROR` (Kotlin: `"<SimpleName>: <message>"`; the subscriber gets a `RemoteHandlerException`
/ `RemoteHandler`), and both remove it. With no matching subscription a call does nothing, so a
service may emit unconditionally; a Kotlin filter that throws skips its subscription (logged), never
the others. Kotlin defers every call made inside a thread-bound Spring transaction
(`@Transactional`, `TransactionTemplate`; a reactive Reactor-context transaction is not seen) to
after the commit and drops it on a rollback, so a subscriber never sees an update of data that was
never committed; the matching subscriptions and the filter are evaluated at delivery and a failure
there is logged, never thrown at the committer. Rust has no such hook: a handler that writes in a
Mongo transaction emits after its `commit_transaction`, or a subscriber sees an update of a write
that may roll back. A Rust call never waits for the hub stream (one task per subscription writes in
order).

**The call.**

```kotlin
// suspend fun <I, U> subscribe(query: SubscriptionQuery<I, U>, options: SubscriptionOptions = SubscriptionOptions()): SubscriptionResult<I, U>
val result = queryBus.subscribe(WatchAccount("acc-1"), SubscriptionOptions(initialCredit = 32))
render(result.initial)                          // returned once the initial result arrived
result.updates.collect { change -> render(change) }   // completes when the handlers do; take(n) or result.cancel() cancel it
```

```rust
// Sender::subscribe(self: &Arc<Self>, &q, SubscriptionOptions) -> Result<Subscription<Q>, MessagingError>
let sub = app.sender().subscribe(&WatchAccount { account_id }, SubscriptionOptions {
    timeout: Some(Duration::from_secs(5)), max_results: 0, priority: None, initial_credit: 32,
}).await?;                                      // returns once the initial result is in
render(&sub.initial);
let mut updates = sub.updates;                  // BoxStream<'static, Result<Q::Update, MessagingError>>
while let Some(change) = updates.next().await { render(&change?); }
```

| | Kotlin | Rust |
|---|---|---|
| Options | `SubscriptionOptions(timeout: Duration? = null, maxResults: Int = 0, priority: Int? = null, initialCredit: Int = 64, retry: RetryPolicy? = null)` (`maxResults >= 0`, `initialCredit >= 1`) | `SubscriptionOptions { timeout: Option<Duration>, max_results: u32, priority: Option<i32>, initial_credit: u32 }` (`Default`: `initial_credit` 64; 0 reads as 64; retry: `Config.hub_retry`) |
| Result | `SubscriptionResult(initial: I, updates: Flow<U>)` with `cancel()`; `updates` is hot (fed from the open on) and can be collected once | `Subscription<Q> { initial: Q::Initial, updates: BoxStream<'static, Result<Q::Update, MessagingError>> }` with `cancel(self)`; owned, no borrowed variant (`app.sender()` is the `Arc`) |
| An update that does not decode | `InvalidMessageException` fails the flow; the subscription is cancelled | `Serialization` as the last item; the subscription is cancelled |
| An initial result that does not decode | `subscribe` fails with `InvalidMessageException` and cancels | `subscribe` fails with `Serialization` and cancels |

A Kotlin controller may return `updates` (an SSE endpoint): the caller's bearer token and trace
context are read when `subscribe` is called, not when the flow is collected. A subscription always
goes through the hub, also from a service that owns the type.

- **Options.** `timeout` bounds the **initial request only**: the hub queue wait plus the handler,
  sent as `timeout_ms` under the usual rules (default `request-timeout` / `Config.hub_request_timeout`,
  else the hub's bound); there is no idle timeout, a quiet subscription is not a broken one.
  `maxResults` / `max_results > 0` ends the subscription after that many **updates** (the initial
  result does not count): the hub sends the clean end and cancels the handlers' side. `priority` is
  the initial request's (default per type, else 0). `initialCredit` / `initial_credit` is the credit
  window, below. The hub may bound a subscription's whole life (`SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION`,
  off by default): `CANCELLED`.
- **Who is asked, and the at-most-once caveat.** The update targets are the live instances of the
  owners **as they are when the subscription opens**: an instance that registers later is never
  added (an update emitted on a new instance is lost to that subscriber), a target that leaves is not
  replaced, and the hub never resubscribes. After a rolling restart a subscription listens to fewer
  instances than serve the type, silently until the last one leaves (`HandlerDisconnected`); there
  is no order between instances (per-instance order is kept). A subscriber that needs every instance
  subscribes again and gets a fresh initial result.
- **Registration order on a handler instance.** The hub writes every `<id>#n` to an instance
  before the `<id>#0` initial request to that same instance, and the library registers the
  subscription **synchronously when it reads `#n`**, before the admission checks. Emits made
  while admission runs are buffered and delivered once it succeeds, or dropped if it fails (a hub
  `Cancel` or a lost stream during admission removes the subscription). So an update emitted
  after the initial result was read on that instance is never lost; across instances the
  at-most-once gap above remains. A panicking or failing filter skips that subscription only, and
  the initial part counts as consumed when `subscribe` returns (rulings 37-40 below).

**Credits and the hub's buffer.** `initialCredit` / `initial_credit` is the window: the hub relays
that many parts (the initial result included) before the consumer took any, and holds further
updates for the subscriber, at most `SNODRA_SERVER_SUBSCRIPTION_BUFFER` (256). One more ends the
subscription with `RESOURCE_EXHAUSTED` ("subscriber buffer (256) exceeded"; the buffered updates are
dropped). The sender's library refills: each time the consumer took `max(1, initial / 2)` parts it
sends `Flow{max(1, initial / 2)}`, **the initial result counting as consumed** (it took a credit), so a window
of 1 cannot stall. No credit goes to the handlers: updates are pushed, an emitter is shared by every
subscriber of its instance, so pausing it for one slow subscriber would stall the others; a consumer
that falls further behind than the buffer loses the subscription and resubscribes. A Kotlin result
that is **dropped without being collected or cancelled** leaves the hub buffering until it reaches
that limit and ends the subscription: collect it or `cancel()` it. Parts carry `seq` 1 for the
initial result and 2, 3, ... for the updates (the hub numbers them); the sender checks the
continuity and `ReplyEnd.parts` (which includes the initial result), and a mismatch fails with
`InvalidMessageException` / `InvalidMessage` ("subscription `<type>` lost N part(s)") and cancels.

**Endings and errors.** `subscribe` returns once the initial result is in, so everything before
that is the call's error, mapped **exactly like a unary error of the same hub code**; afterwards
`updates` completes on a clean end and fails (Kotlin) or yields the error as its last item (Rust)
with the same mapping.

| Situation (hub code) | Kotlin | Rust |
|---|---|---|
| No owner, or no live instance listing the type (`NO_HANDLER`) | `NoHandlerException` | `NoHandler` |
| A command type, a duplicate id, or the wrong mode for the handler (`INVALID_REQUEST`) | `InvalidMessageException` | `InvalidMessage` |
| The initial request failed (`HANDLER_ERROR`; `UNAUTHENTICATED` and `PERMISSION_DENIED` as for unary), or a handler's emitter ended with an error | `RemoteHandlerException` (`UnauthenticatedException`, `AccessDeniedException`) | `RemoteHandler` (`Unauthenticated`, `AccessDenied`) |
| No initial result within `timeout` (`TIMEOUT`) | `MessageTimeoutException` | `Timeout` |
| A gap in `seq`, or `ReplyEnd.parts` above the parts received (checked locally) | `InvalidMessageException` | `InvalidMessage` |
| The last handler instance left (`HANDLER_DISCONNECTED`); also the initial handler leaving before its result | `HandlerDisconnectedException` | `HandlerDisconnected` |
| The hub queue or session buffer was full, the subscriber's buffer overflowed, or an instance is at its subscription limit (`RESOURCE_EXHAUSTED`) | `HandlerBusyException` (the message carries the hub's reason) | `HandlerBusy` (the reason is only logged, at debug) |
| The subscription outlived `SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION` (`CANCELLED`) | `StreamCancelledException` | `MessagingError::Cancelled` |
| The stream to the hub breaks | `HubConnectionLostException` | `HubConnectionLost` (a loss while the request still sat in the outbound buffer moves it to the next live hub with the same id) |
| No initial result within the local guard (a hub that never answers) | `MessageTimeoutException` | `Timeout` |

The only local guard is on the initial result: the hub's deadline bound for the request plus 1 s,
as for a unary request; there is none after it. A clean end (every handler completed, or
`maxResults` updates relayed) completes `updates`.

**Cancel.** Cancelling the collector (Kotlin: `take(n)`, a cancelled coroutine, an exception in it)
or `SubscriptionResult.cancel()` (`cancel()` also completes `updates`); Rust: `Subscription::cancel`,
dropping the `Subscription` or just its `updates` before the end. Each sends `Cancel` to the hub once
(Rust: `Cancel{id, "dropped by the sender"}`, best effort, from the drop), which cancels every
target: the handlers' subscriptions are removed. On the handler side a hub `Cancel` (the subscriber
left, `maxResults`, the buffer, the hub's limits) removes the subscription, a **lost hub stream
removes every subscription it carried** (the hub forgot them with the session; they are not restored
on reconnect), and **shutting the application down ends every subscription served here with a clean
`ReplyEnd`**, best effort (Rust bounds it to 2 s): the subscriber's updates complete once every other
target has too, or fail with `HandlerDisconnected` if the stream closed first.

**Retry.** The query rules of Send options, priority and retry
apply **only until the initial result**, to an end with an error and to a gate `Error` as to an
error before any part (`HubUnavailable`, `NoHandler`, `HandlerBusy`, `HandlerDisconnected`,
`Timeout`, `HubConnectionLost` are retried; handler errors, `Cancelled` and `InvalidMessage` are
not); a retry is a new subscription with a fresh id (with several hubs, round-robin to another live
one), so no update is ever delivered twice. As for a unary query the
timeout is a **budget**: each attempt sends what is left of it. After the initial result nothing is
retried and nothing resubscribes: the caller resubscribes (and gets a fresh initial result).
Kotlin takes the configured policy or `SubscriptionOptions.retry`; Rust takes `Config.hub_retry`.

**Limits.** `snodra.messaging.hub.max-subscriptions` / `SNODRA_SERVER_MAX_SUBSCRIPTIONS` (1024, the
hub's per-instance default) bounds the subscriptions one instance serves over every hub; beyond it
the instance refuses with `ReplyEnd{RESOURCE_EXHAUSTED, "subscription limit (N) reached"}` and the
hub ends the whole subscription with it (the subscriber's call fails or `updates` ends with
`HandlerBusy`). A subscription holds **no handler permit**, so `max-concurrent-handlers` does not
apply to it (only the initial request takes one, for its duration). The hub's own buffer, per-instance
limit and maximum duration are its settings.

**Shared rulings (both libraries)**, continuing the numbering of the stream rulings
(ADR 0017, P4c client slices):

28. **The initial request is recognised by its `#0` id**; a subscription handler answers it, and a
    unary request for the type (any other id) is `INVALID_REQUEST`.
29. **The initial part counts as consumed in the credit refill**: `Flow{max(1, initial / 2)}` after
    every `max(1, initial / 2)` parts consumed, the initial one included, so a window of 1 works.
30. **`timeout` bounds only the initial request**, and retries before it use the remaining budget
    (the unary rule, unlike streams' idle timeout).
31. **No local guard after the initial part**; the initial guard is the hub's bound + 1 s.
32. **`seq` must be 1 for the initial part and continue 2, 3, ...; `ReplyEnd.parts` includes the
    initial part**, else "subscription `<type>` lost N part(s)".
33. **A subscription holds no handler permit**; the handler-side limit refuses with
    `ReplyEnd{RESOURCE_EXHAUSTED, "subscription limit (N) reached"}`.
34. **A hub `Cancel` removes the subscription; a lost hub stream drops the subscriptions it carried,
    with no restore on reconnect.**
35. **Shutdown ends every subscription with a clean `ReplyEnd`**, best effort.
36. **Updates are at most once and nothing resubscribes.**

37. **A subscription is registered synchronously when its `#n` request is read, before
    admission** (the identity check). A hub `Cancel` or a lost stream during admission removes it.
    Emits made during admission are buffered and delivered once admission succeeds, or dropped if
    it fails.
38. **An update emitted after the initial result was read on that instance is never lost**: the
    hub writes `#n` before `#0` to the same instance, and the `#n` read registers the
    subscription. Across instances the at-most-once gap remains (36).
39. **A panicking or failing filter skips that subscription only**; the other subscriptions of
    the emitter still get the emit, and the failing one is not ended.
40. **The initial part counts as consumed when `subscribe` returns**, for the credit refill (29).

Documented divergence: Kotlin's busy error keeps the hub's reason (`HandlerBusyException`'s
message), Rust's does not (`HandlerBusy(type)`, the reason is logged at debug), and only Kotlin defers
emits to after the commit of a Spring transaction.

With several hubs a subscription goes to one live hub (unkeyed round-robin).

Sandbox: `examples.WatchCounter(name)` is a shared subscription type served by service-b (Kotlin,
`@QueryHandler(shared = true)` returning `Counter`, an in-memory counter per name) and service-c
(Rust, `shared_subscription_query`); the updates (`CounterChanged`) come from
`POST /counters/{name}/increment` on service-b (port 8092) and from the command
`examples.IncrementCounter(name, service)`, owned by service-c and sent by service-a's
`POST /counters/{name}/increment`. Service-a's `GET /subscribe/counter?name=&updates=N&timeoutMs=`
subscribes, collects the initial result and N updates (or until the timeout), cancels and returns
`{"initial":...,"updates":[...]}`; `GET /subscribe/open` scatter-gathers the shared query
`examples.OpenSubscriptions`, how many subscriptions each owner instance serves. The examples smoke
(steps 20, 20b, 20c) checks the initial result and four updates from both services, that nothing is
left subscribed afterwards, and the initial result for an unknown name (see
`snodra-messaging/examples/README.md`).

## Sagas and deadlines

A **saga** is a long-running process that reacts to events, keeps its own state, sends commands and events, waits, and
ends. It is the saga model: `@Saga`, `@StartSaga`, `@SagaEventHandler`, `@EndSaga`, deadlines, built for what Snodra
needs it for: driving **integrations with external systems**, that is asking an outside system to do something, waiting
for its answer and handling the answer that never comes. Sagas live in the Kotlin library, inside each service, against
that service's MongoDB and Kafka consumer; the hub only carries the commands a saga sends to another service. Decision and
rulings: ADR 0021. Service authors start with the "Sagas" section of the
`snodra-messaging` README and the sandbox's postcard saga (`snodra-messaging/examples/README.md`).

Kotlin (S1) and Rust (S2) both have it, on the same collections
(ADR 0021). The sections below describe the model with the
Kotlin API; Rust gives the crate's API next to it and what differs.

### Programming model

```kotlin
@Saga
class PaymentSaga {
    // State: plain properties, persisted as JSON after each handled message.
    var orderId: String? = null
    var paymentRef: String? = null
    var timeoutDeadline: String? = null

    @StartSaga
    @SagaEventHandler(associationProperty = "orderId")
    fun on(e: OrderPlaced, saga: SagaLifecycle, commands: SagaCommands, deadlines: DeadlineManager) {
        orderId = e.orderId
        paymentRef = "pay-${e.orderId}"
        saga.associateWith("paymentRef", paymentRef!!)                // later events find this instance by paymentRef
        commands.send(RequestCharge(paymentRef!!, e.amount))          // dispatched after the transaction commits
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

| Element | Meaning |
|---|---|
| `@Saga(name = "")` | The class is discovered at startup (by scanning the application's packages) and needs a no-argument constructor. A new instance is built per saga, never a Spring singleton. `name` is the type's name in `sagas.type`, default the class's fully qualified name; set it to keep stored sagas valid when the class is renamed or moved |
| `@StartSaga(forceNew = false)` | On a `@SagaEventHandler`: the handler may create an instance. With `forceNew = false` it does so only when no live instance matched any handler for the event, and at most one live instance exists per start association. `forceNew = true` always creates a new instance, with no start key |
| `@SagaEventHandler(associationProperty, keyName = associationProperty, associationHeader = "", payloadType = Event::class)` | The event's property value (or, when `associationHeader` is set, that message header's value; the property may then be left empty) is looked up as the association `keyName = value` among the live instances of this saga type. Every match handles the event. `keyName` defaults to the property (the header when there is no property). `payloadType` narrows a handler declared on a supertype of the event |
| `@EndSaga` | The instance ends after the handler returns. Allowed on saga event handlers and deadline handlers |
| `@DeadlineHandler(deadlineName)` | Runs when a deadline of that name, scheduled by this instance, falls due |

**Handler parameters.** The first parameter of a saga event handler is the event (a concrete `Event` class, or a supertype
narrowed by `payloadType`; the bare `Event` interface is an error). A deadline handler's first parameter is the deadline's
payload, or absent. After that, in any order and all optional:

| Parameter | What it is |
|---|---|
| `SagaLifecycle` | `sagaId`, `associateWith(key, value)`, `removeAssociationWith(key, value)`, `end()` (ends the instance after the handler returns, as `@EndSaga` does) |
| `SagaCommands` | `send(command, routingKey? = null)` and `publish(event, key? = null)`. They **record** the message in the saga's transaction; it is sent after the commit, in call order (see below). A saga never waits for a reply |
| `DeadlineManager` | `schedule(Duration \| Instant, name, payload? = null): String` (returns the deadline id), `cancel(id)`, `cancelAll(name)`. Saga-scoped: a deadline belongs to the instance that scheduled it |
| `MessageContext` | The message's id, type, correlation id, user id and headers. For a deadline handler, `messageId` is the deadline's id, `type` is `deadline:<name>` and `correlationId` is that of the message that scheduled the deadline (the commands the handler sends carry it too) |
| any Spring bean, by type | Looked up when the handler runs. Collaborators are parameters, not injected fields, so a saga's state is data only and a stored instance never needs re-injection. Enums, collections, maps, arrays, primitives, `String` and the like are not beans: such a parameter is a startup error. So is a `CommandBus`, `QueryBus`, `EventBus`, `RawCommandSender`, `RawEventPublisher` or `HubBus` (or a subclass or implementation of one): it would send at once, outside the saga's transaction, with no relay ordering, retry or idempotency key. A saga sends through `SagaCommands` |

**Rules**, checked at startup with an error naming the class and method: every saga event handler's first parameter is an
`Event` and its association property exists on it; a handler is not `suspend` (it runs inside the saga's thread-bound Mongo
transaction); a saga has at least one `@StartSaga` handler; `@StartSaga` and `@EndSaga` only go on handlers; two classes do
not share a saga type name; a deadline name has one handler per saga; and a fresh instance of the class round-trips through
the library's Jackson codec (the state is persisted as JSON, so a property the codec cannot carry fails the startup, not the
first event).

**Order and matching.** Several handlers of one saga for one event type run in **method-name order** (then parameter types):
Kotlin reflection does not expose declaration order. A handler runs on an instance only if its own `keyName = value` is among
that instance's associations. An instance that ends in a handler does not run the remaining handlers of that event. When no
live instance matched any handler, the first `@StartSaga` handler (in that order) that is not `forceNew` and whose association
value is present creates one, with that association and the start key `"<type>|<key>=<value>"`, and the new instance then runs every handler of
that event whose key and value are that association; every `forceNew` start handler creates its own instance as well. The start key lives with its association: when a handler
removes that association (`removeAssociationWith` of the start handler's key and value) the instance's start key is released,
so a later start event for the same value creates a new instance; the old instance goes on under its other
associations.

### Delivery and consistency

In plain words, for a service with a saga:

- **Where events come from.** The service's Kafka consumer on `snodra.events`, and the three inbound channels below. All of
  them go through one local dispatcher that runs the ordinary `@EventHandler`s first, in the transaction they always had, and
  then each saga type, each in its own transaction; the saga stage runs even when an ordinary handler failed (the failure is
  then thrown, so the consumer retries or skips the record by its own rules). All of it finishes before the Kafka offset is
  acknowledged. A record that only a saga wants is processed; before sagas it would have been skipped.
- **Exactly once per instance.** Per (event, saga type), one Mongo transaction inserts the marker `saga:<sagaType>:<eventId>`
  in `processed_events`, runs the handlers of every instance the event reaches, and writes each instance's state, its dispatch
  entries and its deadline changes. The marker is in the same transaction as the state, so a redelivered event finds it and is
  skipped. A handler exception rolls everything of that attempt back.
- **Never two events at once for one instance.** The state is written with an optimistic version check. A conflict (another
  event changed the instance first, two start events for one key, a Mongo write conflict) aborts the transaction and retries
  the event.
- **A saga that cannot handle an event does not stop the others, and does not stop the consumer.** After `sagas.max-attempts`
  attempts (5) for conflicts, or two quick attempts for a handler that throws, the event is parked in `saga_failures` together
  with its marker, so the consumer moves on. See
  [Failures](#failures-and-the-sagafailures-api).
- **Commands and events a saga sends leave after the commit.** `SagaCommands.send` and `publish` write entries to the
  `saga_dispatch` collection (a saga-side outbox) in the saga's transaction. A relay in every service instance sends them
  once the transaction committed, one saga's entries in the order they were recorded and different sagas in parallel. A
  command is therefore never sent for a state that rolled back, and a state that committed always sends its commands, also
  after a crash. **At least once:** a command is marked sent after its reply, so a crash in between sends it again with the same
  `idempotency-key` header (`<sagaId>:<seq>`). An event entry goes into the ordinary outbox and is marked sent in one
  transaction (exactly once into the outbox; the outbox's own at-least-once to Kafka applies from there).
- **The order is per saga.** A command in retry holds back that saga's later entries and nobody else's; a command that failed
  for good does not.
- **Every handler of a saga command must be idempotent by its `idempotency-key`.** The relay retries after a timeout, a lost
  connection or a lost stream, because the command may or may not have run (a bus would not retry then; a saga command carries
  a key, so the relay does), and it re-sends after a crash between the send and the mark. A handler that is neither an
  `@IdempotentHandler` nor naturally idempotent (an upsert by the key, a check of its own) **can run twice** for one command.
  Make the target an adapter with `@IdempotentHandler`, or key its own effect on `headers['idempotency-key']`.
- **A step that must not run after the step before it failed is sent from the success event of that step.** The relay sends a
  saga's later entries after a permanently failed one (the saga decides what a failure means), so step 2 recorded together
  with step 1 is sent even when step 1 failed. When step 2 only makes sense after step 1 succeeded, do not record it in the
  same handling: send it from the handler of the event that says step 1 succeeded (the reply the partner sends back, a
  webhook, a poll result), and let `SagaCommandFailed` end or compensate the saga.
- **A slow or hung send holds back its own saga only.** The relay hands each saga to a small worker pool (4 threads) and never
  waits for the whole batch: the polling thread goes on, skips the sagas already in flight on this instance, and the lease of
  a saga whose send is still running is renewed (every third of `sagas.relay.lease`), so another instance does not take it over
  and send the same entry again. A local adapter has no timeout of its own, so **an adapter must set I/O timeouts well below
  `sagas.relay.lease`**: a call that never returns keeps its saga blocked and one of the four worker threads busy, and four
  such calls stop dispatch on that instance.
- **Local before hub.** The relay sends a command by the hub bus's rules: a handler in the same service is invoked
  in-process (an adapter in the saga's own service is the intended case), else it goes through the hub. A service with
  `hub.enabled=false` sends to its own handlers only; a type it does not handle is `NO_HANDLER`.
- **Identity.** A saga's command carries no user token and no caller identity (the triggering event's user is not a caller).
  A handler with `@RequiresAuthentication` refuses it with `DENIED`, until the `snodra-system` service identity
  (06-security.md, planned) is forwarded.
- **Time** comes from an injectable `Clock` bean; the test fixture advances it.
- **Leases need synchronised clocks.** The relay's saga lease, the deadline claim and the `external_calls` lease are
  timestamps written by one instance and compared with the clock of another. Keep the instances' clocks in step (NTP, or the
  platform's time sync): a clock that runs ahead by more than a lease lets another instance take work over while it is still
  running, which at-least-once delivery and the idempotency key absorb but which costs duplicate calls.

### Command failures

A saga does not wait for a reply. A command the relay could not deliver, or that failed, comes back as the library event
`SagaCommandFailed(sagaId, commandType, idempotencyKey, reason, message)` (`@MessageType("snodra.SagaCommandFailed")`),
dispatched **locally** (never published to `snodra.events`; dedupe id `failed:<sagaId>:<seq>`). A saga handles it with
`@SagaEventHandler(associationProperty = "sagaId")`. The runtime routes it to the saga instance that sent the command **by its
id** (load by `sagaId`, check that the type has a `SagaCommandFailed` handler): no association is needed, and a saga that
also associated itself with `sagaId` keeps working. When the saga type has no such handler or the saga has ended, and no
ordinary `@EventHandler` took the event either, it is logged at error and counted (`snodra.saga.command.failures`).

| `reason` | When |
|---|---|
| `NO_HANDLER` | Nobody handles the command type, in a service **without a hub** (it only knows its own handlers). Through the hub it is **transient** (a rolling redeploy of the target service looks the same): the relay retries it with backoff and a type nobody ever handles ends as `EXHAUSTED` after `sagas.relay.max-attempts` attempts (about 8.5 minutes with the defaults) |
| `DENIED` | The handler requires authentication (or denies the caller): a saga command has no caller |
| `INVALID` | The handler could not read the payload |
| `FAILED` | The handler failed (any other error), including an `@IdempotentHandler` whose first call failed for good |
| `UNKNOWN_OUTCOME` | An idempotent adapter crashed in the middle of its call and cannot tell whether the call happened |
| `EXHAUSTED` | A transient failure persisted through all `sagas.relay.max-attempts` attempts |

The relay retries only **transient** failures: `HubUnavailable`, `MessageTimeout`, `HandlerDisconnected`,
`HubConnectionLost`, `HandlerBusy`, the hub's `NoHandler` (not the local sender's), an adapter's `RetryableExternalException`, and an unexpected non-messaging failure of the
sender. The wait before attempt n+1 starts at `sagas.relay.initial-backoff` and doubles up to `sagas.relay.max-backoff`
(jittered ±20 %). Every other failure is permanent and becomes a `SagaCommandFailed` at once. This is the relay's own table:
unlike a bus call (see Send options, priority and retry), it also retries after a timeout or a
lost connection, because a saga command carries an idempotency key. Adapters never retry internally: a retryable external
failure is thrown as `RetryableExternalException` and the relay owns the backoff, so retries never stack and no relay thread
sleeps inside an adapter.

A permanent failure is a known outcome, so it is **persisted first**: the entry gets `failedAt`, `failureReason`,
`failureMessage` and `noticePending` in one update, and only then is the `SagaCommandFailed` dispatched. The command is never
sent again, whatever happens to the notice. A notice that cannot be delivered (an ordinary `@EventHandler` for it throws, the
store is down) is retried by the relay with its own bounded backoff (`sagas.relay.max-attempts` attempts, the same backoff as
a command; its dedupe id `failed:<sagaId>:<seq>` and the saga's marker make every repeat harmless); when the attempts run out
it is logged at error and counted in `snodra.saga.command.failures`, and the saga never hears of that failure. A saga's later
entries are sent after a permanently failed one: the saga decides what the failure means (end, compensate, ask a person).

How a failure kind reaches the relay: it travels as `HANDLER_ERROR` with a small JSON marker in `details`
(`{"Snodra":"retryable"}`, `{"Snodra":"unknown-outcome"}`), so it is the same whether the adapter runs in the saga's service or in
another one.

`SendOptions.headers` carries the relay's `idempotency-key` and `saga-id` to the handler's `MessageContext.headers` (hub or
local). It is a general option: extra request headers, never the reserved `authorization`, `traceparent`, `tracestate`,
`correlation-id` and `correlationId`.

### Deadlines

`DeadlineManager.schedule(after | at, name, payload)` records a deadline in the saga's transaction; `cancel(id)` and
`cancelAll(name)` mark it `CANCELLED` in the same one. A deadline of an ended saga is cancelled (when the saga ends, and again
if one is found due later). The payload may be any object the library's codec can write; it is stored as JSON text with its
type name (the class's `@MessageType` name, else its class name) and decoded to the first parameter of the `@DeadlineHandler`.

A scheduler in every service instance polls the due deadlines (`deadlines.poll-interval`), claims one at a time with a lease
(`findAndModify`: `claimedBy`, `claimedUntil = now + deadlines.lease`) and fires it in a transaction: load the saga, run the
handler, write the state, mark it `FIRED`. Several instances can run the scheduler; the lease makes each deadline fire on one of
them. If firing fails, or the instance dies, the claim is left alone and the deadline fires again when the lease expires: **at
least once**, never before its due time, never for a cancelled deadline or an ended saga. A deadline whose saga is gone or ended,
or whose saga type has no handler with that name (logged at error), is cancelled. Time is the injectable `Clock`.
The overdue gauge `snodra.deadlines.due{name}` shows deadlines past their time that have not fired.

Deadlines belong to sagas only: there are no aggregate- or bean-scoped deadlines.

### Integration toolkit

The rule for all of it: **the edge of the service turns the outside world into Snodra messages, deduplicated.** A saga only
speaks Snodra messages: it never performs an HTTP call or produces to a foreign broker. The saga's outbound command is handled
by an adapter in the same service, and the external system answers through one of three channels. All three end as an ordinary
Snodra event routed to the saga by association.

#### Outbound: idempotent adapters

An adapter is an ordinary `@CommandHandler` (or `@EventHandler`) in the service that owns the saga, made safe to be called
again with the same key by `@IdempotentHandler(key = "<SpEL>", externalIdempotent = false)`.

- The key is a SpEL expression over `message` (the decoded message) and `headers` (`MessageContext.headers`). The default is
  `headers['idempotency-key']`, the `<sagaId>:<seq>` the relay sets. An adapter that polls puts the attempt in the key,
  `"'poll:' + message.jobId + ':' + message.attempt"`. A key that cannot be evaluated or comes out empty fails the call.
- Each call is recorded in `external_calls` under its key. `SUCCEEDED`: a repeat returns the stored reply without running the
  body. `FAILED`: a repeat re-throws the stored error (permanent). A `RetryableExternalException` from the body removes the
  record, so the next call (the relay's retry) starts afresh.
- **A crash in the middle of a call** leaves the record `IN_PROGRESS`. A repeat within the lease
  (`external.calls.lease`, 5 min) is another call in flight and is retryable. Past the lease the outcome is unknown, and the
  adapter's declaration decides: `externalIdempotent = false` (default) moves the record to `UNKNOWN`, never calls again on its
  own and reports `SagaCommandFailed(UNKNOWN_OUTCOME)`, so the saga decides (poll the partner, compensate, ask a person);
  `externalIdempotent = true` (the partner de-duplicates by the key the adapter passes it) takes the record over and calls
  again. An adapter may also throw `ExternalCallUnknownOutcomeException` itself when it sees a connection break after the
  request went out: the record is then left `UNKNOWN` (not `FAILED`), so a redelivery reports the unknown outcome again too.
- **A call that ran but whose success could not be recorded** (the store went away right after the body returned) is an unknown
  outcome as well, never a failed call: the record is moved to `UNKNOWN` (best effort; the lease does it otherwise) and the call
  reports `UNKNOWN_OUTCOME`; with `externalIdempotent = true` it is retryable instead, because the partner de-duplicates the
  repeat.
- Pass the key to the external system when it accepts one (an `Idempotency-Key` header).
- The bookkeeping runs in short transactions of its own (`REQUIRES_NEW`), so a rollback of the caller's transaction does not
  forget a call that happened and the bookkeeping itself never holds one open. **The body of an `@IdempotentHandler`
  `@EventHandler` runs inside the transaction of stage 1** (the dispatcher runs the ordinary handlers in one Mongo
  transaction), so an external call there holds that transaction open for as long as it takes (MongoDB's transaction lifetime
  limit, 60 s by default, applies). A `@CommandHandler` adapter (what the relay calls) runs in no Mongo transaction. Prefer
  command handlers for slow external calls.
- **`idempotency-key` is just a header**: any sender of a command to the adapter can set it, including a client of the hub
  that is not a saga. A sender that knows or guesses a key can replay a stored reply or make the adapter answer a stored
  failure. Keep adapters internal (do not expose their command types to services or clients you do not trust, and restrict
  who may send them in the hub's access rules), and give keys that are not guessable (the relay's `<sagaId>:<seq>` carries a
  random UUID).
- The handler must not be `suspend` (a startup error), and must not be a query handler. A service where an `@IdempotentHandler`
  is registered but the interceptor is missing (`calls.enabled=false`, or an adapter outside the application's packages with
  the property unset) **fails the startup**, naming the handler and the property. The interceptor and the `external_calls` indexes exist when a class in
  the application's packages has an `@IdempotentHandler` method; `snodra.messaging.external.calls.enabled` overrides that
  (`true` when the adapter lives outside those packages, `false` to switch it off).

#### Inbound 1: a partner's Kafka topic

```yaml
snodra:
  messaging:
    external:
      kafka:
        sources:
          printer:                                   # the source's name
            topic: printer.events
            # bootstrap-servers: partner-kafka:9092  # default: snodra.messaging.kafka.bootstrap-servers
            # group-id: ...                          # default: <service-name>.external.printer
            # properties: { security.protocol: SSL } # extra consumer properties
```

and a bean **named like the source** that implements `ExternalRecordTranslator`:

```kotlin
@Component("printer")
class PrinterTranslator(private val codec: JsonCodec) : ExternalRecordTranslator {
    override fun translate(record: ConsumerRecord<String, ByteArray>): TranslatedEvent? {
        val n = codec.decode(record.value(), PrinterNotification::class)
        return TranslatedEvent(PostcardPrinted(n.jobId, n.name), dedupeKey = n.deliveryId)   // null ignores the record
    }
}
```

The library runs one consumer per source (one thread; a partner topic is read in order, group `<service-name>.external.<name>`).
Each record is translated and dispatched **locally**: the service's `@EventHandler`s, then its sagas, as for any event. A
translated event is **not** republished to `snodra.events`; a service that wants to share it publishes its own Snodra event
from a handler. The dedupe id is `<name>:<partition>:<offset>`, or `<name>:<dedupeKey>` when the translator gives a
`dedupeKey` (the partner's own id: two records with it are applied once). **Without a `dedupeKey` the id is only as good as the
topic**: if the partner deletes and recreates the topic, the new records start again at offset 0 and carry ids that the
`processed_events` markers of the old ones already hold (they live `idempotency.retention`, 30 days), so for up to 30 days the
new records are skipped as duplicates, silently. A partner that can recreate its topic needs a `dedupeKey` (its own id of the
event), or the service needs a different source name for the new topic. Delivery is the main consumer's: manual
acknowledgement after the dispatch, at least once. A translator or handler exception redelivers the record up to
`kafka.consumer.max-attempts` times in all (5), 1 s apart, then logs it (never the payload) and skips it, offset committed. A
`null` translation is acknowledged and applies nothing. The consumer starts at `earliest` for a new group. `properties` are
extra consumer properties; bootstrap servers, group id, deserializers (`String` key, `byte[]` value) and auto-commit
(`false`) are fixed by the library: a `properties` entry for one of those keys fails the startup, naming the source and the key. A source without its translator bean fails the startup, naming it.
The partner topic is not auto-created by the library, and in the sandbox Kafka does not auto-create it either.

#### Inbound 2: webhooks

The service exposes its own endpoint, verifies the request with `WebhookSignatureVerifier`, turns the body into an `Event` and
calls `ExternalEventIngress.accept(source, dedupeKey, event, headers = emptyMap())`:

- `verify(secret, previousSecret, headers, body)`: `X-Snodra-Webhook-Secret` holds the secret itself, or `X-Snodra-Signature`
  holds the HMAC-SHA256 of the **raw** body keyed by the secret, as hex or `sha256=<hex>` (either case). The current or, during
  a rotation, the previous secret verifies. Header names are case-insensitive, every comparison is constant time, an empty
  secret is ignored (a service with none configured verifies nothing). The same rules as the provider's webhook of the
  the service. Verify the raw bytes before parsing.
- `accept` dispatches locally and **synchronously** on the calling thread (ordinary handlers, then sagas, committed when it
  returns) under the dedupe id `<source>:<dedupeKey>`, and answers `ACCEPTED` or `DUPLICATE`. `dedupeKey` is the partner's
  own event or delivery id, stable across its retries. After the dispatch succeeded it writes the marker
  `ingress:<source>:<dedupeKey>`; a later call that finds the marker answers `DUPLICATE`. It is **not one transaction**: the
  handlers' and sagas' transactions are their own, and the marker comes after.
- A handler failure is thrown: answer 5xx, the partner retries and the retry applies what did not commit. A call that
  returned is final. An event that no handler and no saga of the service takes is `ACCEPTED` with a warning and **no marker**
  (the partner must not retry what the service will never use).
- `accept` blocks: call it from a request thread, not from a coroutine that switches threads. `headers` are extra message
  headers for the handlers (a saga's `associationHeader` reads them); a `correlationId` header becomes the correlation id.

A ready `@RestController` is not provided (authentication, body shape and response codes differ per partner); the
`snodra-messaging` README shows the controller, and the sandbox's `PrinterWebhookController` is one.

#### Inbound 3: long polling

No new machinery. The saga schedules a polling deadline; the deadline handler sends a poll command to the adapter; the adapter
asks the external system and publishes a result event when there is one, deduplicated by `@IdempotentHandler` on a key that
includes the poll attempt; the saga reschedules the poll or ends. The sandbox's `poll-*` greetings do exactly this.

### Saga configuration

Keys under `snodra.messaging` (durations accept `200ms`, `5s`, `7d`; every duration must be positive and every count at least 1,
else the startup fails naming the key, also in a service with no saga):

| Key | Default | Meaning |
|---|---|---|
| `sagas.enabled` | `true` | Switch for the saga runtime, the dispatch relay and the deadline scheduler. They exist only when the application has a `@Saga` class (found by scanning its packages) anyway |
| `sagas.max-attempts` | `5` | Attempts per saga event (first try included) for conflicts (a version check, a start-key duplicate, a Mongo write conflict or transient transaction error) before the event is parked in `saga_failures`; the same bound for firing a deadline. Backoff 200 ms doubling to 5 s. A handler exception gets two attempts in all, at most 50 ms apart, then the event is parked |
| `sagas.ended-retention` | `30d` | Ended sagas are deleted this long after they ended (TTL index on `sagas.endedAt`) |
| `sagas.dispatch-retention` | `7d` | Dispatched `saga_dispatch` entries are deleted this long after they were sent (TTL index on `dispatchedAt`) |
| `sagas.relay.poll-interval` | `500ms` | How often the dispatch relay looks for entries that saga handlers recorded |
| `sagas.relay.lease` | `30s` | How long a relay instance holds one saga's dispatch order before another instance may take over (a crashed instance's lease expires). Renewed before each entry and, every third of the lease, while a send is running. Needs synchronised clocks across the instances (NTP): the expiry is compared with each instance's own clock |
| `sagas.relay.max-attempts` | `10` | Attempts per command for transient failures (first try included) before it becomes `SagaCommandFailed(EXHAUSTED)` |
| `sagas.relay.initial-backoff` | `1s` | Wait before the second attempt of a command; doubles per attempt up to `max-backoff` |
| `sagas.relay.max-backoff` | `5m` | Upper bound of one wait between attempts of a command |
| `deadlines.poll-interval` | `1s` | How often the deadline scheduler looks for due deadlines |
| `deadlines.lease` | `30s` | How long a claimed deadline stays reserved for the instance that claimed it; an expired claim lets it fire again (at least once) |
| `deadlines.retention` | `7d` | Fired and cancelled deadlines are deleted this long after (TTL index on `deadlines.finishedAt`) |
| `external.calls.enabled` | unset | Whether the idempotency interceptor and the `external_calls` indexes exist. Unset: they exist when a class in the application's packages has an `@IdempotentHandler` method. `true` when the adapter lives outside those packages, `false` to switch it off |
| `external.calls.lease` | `5m` | How long an `IN_PROGRESS` external call may take before its outcome counts as unknown (a crash in the middle of the call) |
| `external.calls.retention` | `30d` | `external_calls` documents older than this are deleted (TTL index on `updatedAt`) |
| `external.kafka.sources.<name>.topic` | required | The partner's topic |
| `external.kafka.sources.<name>.bootstrap-servers` | `kafka.bootstrap-servers` | The partner's cluster |
| `external.kafka.sources.<name>.group-id` | `<service-name>.external.<name>` | Consumer group of the source |
| `external.kafka.sources.<name>.properties.*` | none | Extra consumer properties (for example `security.protocol`); bootstrap servers, group id, deserializers and auto-commit are fixed by the library (an entry for one fails the startup). `auto.offset.reset` is `earliest` unless set here |

A source's record retries use `kafka.consumer.max-attempts` (5) with a fixed 1 s wait. Not every knob is a property: the relay's
backoff multiplier (2), parallelism (4 sagas at a time) and batch size (100 sagas per poll), the deadline scheduler's batch
size (100 per poll), the saga retry's backoff, and the gauge sampler's interval (15 s) are constants of the library; every
saga bean is `@ConditionalOnMissingBean`, so a service that needs them different supplies its own.

The saga runtime, the relay and the scheduler are lifecycles that start after the outbox publisher and stop before the event
consumer; the saga indexes (`sagas`, `saga_dispatch`, `saga_dispatch_leases`, `deadlines`, `saga_failures`) and the
`external_calls` index are ensured at startup.

### Metrics and logs

Micrometer is optional. The meters below are registered only when a `MeterRegistry` bean exists **and** the service uses the
toolkit (a saga runtime or an idempotency interceptor bean); an application's own `SagaMetrics` bean replaces them. Prometheus
shows `.` as `_` and adds `_total` to counters. Tag values are saga type names, deadline names, handler labels, outcomes and
reasons, never ids.

| Meter | Tags | Meaning |
|---|---|---|
| `snodra.sagas.started`, `snodra.sagas.ended` | `type` | Counters |
| `snodra.sagas.active` | `type` | Gauge of live (not ended) instances; counted in the database every 15 s |
| `snodra.saga.events` | `type`, `outcome` | Counter per (event, saga type): `handled`, `no_match` (the event reached no instance and started none: a broken association shows up here), `conflict` (an attempt retried), `parked` |
| `snodra.saga.dispatch.pending` | none | Gauge of recorded commands and events not yet sent and not given up on; counted every 15 s |
| `snodra.saga.command.failures` | `type`, `reason` | Counter of `SagaCommandFailed` that nobody took: no live saga with a handler (none, or it ended) and no ordinary handler, or a notice given up after its attempts (`type` is the command's wire type name) |
| `snodra.deadlines.fired` | `name` | Counter |
| `snodra.deadlines.due` | `name` | Gauge of scheduled deadlines past their due time, set by every scheduler poll |
| `snodra.external.calls` | `handler`, `outcome` | Counter per `@IdempotentHandler` call: `succeeded`, `replayed`, `failed`, `retryable`, `unknown` |

While a saga handles a message the SLF4J MDC carries `sagaType`, `sagaId` and `correlationId`. A parked event, a command that
failed for good and an event no one handled are logged at error; an event that matched no instance is logged at debug.

### Failures and the `SagaFailures` API

An event whose saga handler failed all its attempts is **parked** in `saga_failures` (`_id` = `<sagaType>:<eventId>`, with
the event, the headers, the last error and `attempts`), together with its marker so the consumer moves on, counted in
`snodra.saga.events{outcome="parked"}` and logged at error. Nothing retries it by itself. The `SagaFailures` bean is the admin
API; inject it in an admin endpoint or a job of your own:

| Call | Does |
|---|---|
| `list(type? = null)` | The parked events of a saga type (all types when null), the longest waiting first |
| `retry(id)` | Re-delivers the event to the saga type that failed, with the runtime's retries, once the cause is fixed. True when applied, false when unknown or failed again (it then stays, with `attempts` increased and the new error). The failure is deleted in the transaction that applies the event, so concurrent retries apply it once |
| `retryAll(type)` | Retries every parked event of a type; returns how many were applied |
| `discard(id)` | Drops the parked event without applying it. Its marker stays: redelivering the record does not apply it either |

Failing parking itself (the store is down) is the one case where the saga stage throws to the consumer, which redelivers the
record.

A failed ordinary `@EventHandler` is not a saga failure: it keeps the processor's handling (the consumer retries, then hands
the record to the dead-letter mode). The sagas do not depend on it: the dispatcher holds the ordinary handlers' failure, still runs the saga stage and
then throws the failure, so a record the consumer retries or skips has been applied to the sagas, once (their own markers
make the redelivery safe).

Entries of `saga_dispatch` that failed for good (`failedAt` set) and `saga_failures` documents have no TTL.

### Testing

`SagaTestFixture` in `snodra-messaging-test` drives one saga class with events and time, in memory, with no Kafka, MongoDB or
Spring context, on the library's own runtime (see [Testing support](#testing-support)). The README of `snodra-messaging` has an
example.

### What is not supported

- **Replay of past events into a new saga type.** A saga type reacts only to events consumed after it is deployed. A later
  replay would read back through the 30-day retention of `snodra.events`; nothing here rules it out.
- **Sagas across services.** A saga belongs to one service and its database; it talks to others through commands and events.
- **Deadlines outside sagas** (aggregate- or bean-scoped).
- **Service identity for saga commands:** a command to a handler with `@RequiresAuthentication` fails with `DENIED`.
- A visual saga monitor: metrics and logs only.

## Event processors and dead letters

**P6a, built** in both libraries and on the hub. Decision record and the binding contract:
ADR 0022; the hub side:
[hub.md, Event processors](../server/event-processors.md).

- **Named processors.** `@ProcessingGroup("orders")` on a handler class (Kotlin) or
  `builder.event_in::<E, _, _>("orders", handler)` (Rust) runs those handlers in their own Kafka consumer, group
  `<service group>.orders`, with markers `processor:orders:<eventId>`; everything else is in processor `default`, group
  `<service group>.default`, markers `processor:default:<eventId>`. Names match
  `^[a-z0-9][a-z0-9-]{0,47}$` (not `default`). One event type may be handled in several processors. Sagas run only in
  `default`.
- **Moving a handler into a named processor runs it again over the whole topic.** The new group starts at the
  earliest offset the topic still holds and the new marker family `processor:<name>:<eventId>` knows none of its records,
  so the handler runs once more for every event in the topic's retention: harmless for an idempotent projection, but a
  handler with effects outside MongoDB (an email) repeats every one. For such code put only new handlers in the named
  processor, or commit the new group's offsets at the end before the deploy
  (`kafka-consumer-groups --group <service group>.<name> --topic <events topic> --reset-offsets --to-latest --execute`,
  with no running member; records produced between the reset and the old instances' stop are handled by both). There is
  no start position per processor: P6b's reset ([Processor control](#processor-control)) moves the group of a processor
  that already runs.
- **Dead letters.** `snodra.messaging.kafka.dead-letter.mode` (Rust `SNODRA_KAFKA_DEAD_LETTER_MODE`): `collection`
  (default; the `dead_letters` collection, retention `dead-letter.retention`, 30 d), `topic` (`<topic>.dlt`) or `log`
  (log the failure and skip the record). A record whose handlers failed every attempt is parked (`HANDLER_FAILED`) before its offset is
  acknowledged; the later records of its key are parked behind it (`SEQUENCED`; sagas still see them); a malformed
  record is parked as `INVALID` and blocks nothing.
- **Admin API** on every instance: Kotlin bean `DeadLetters`, Rust `SnodraMessaging::dead_letters()`, with `list`,
  `get`, `count`, `retry` (the processor's handlers in the marker transaction, together with the letter's deletion),
  `retryAll` (per key in offset order) and `discard` (which unblocks the key's next letter).
- **Status.** Every 5 s each instance reports its processors to every live hub:
  state, partitions with position, committed offset, high watermark and lag, totals, dead letters and the last error.
  The hub dashboard's Processors page and `GET /api/v1/processors` show them; pausing, resuming and resetting a
  processor and working its letters from the dashboard or the hub's HTTP API is P6b's
  [Processor control](#processor-control).
- **Sandbox.** service-b (Kotlin) and service-c (Rust) each run a named `audit` processor that can be made to fail on
  demand, with example admin endpoints over the dead letters (`/audit/...`); the examples smoke steps 26 to 26h park,
  sequence, retry and discard letters and read them on `GET /api/v1/processors`
  (`snodra-messaging/examples/README.md`).

The library sections of ADR 0022 (Kotlin, Rust) record what each slice built and decided.

## Processor control

**P6b, built** in both libraries and on the hub. Decision record and the binding contract:
ADR 0023 (its Kotlin and Rust sections hold each library's
rulings, "Differences between the libraries" what differs); the hub side, its routes, credentials and curl examples:
[hub.md, Processor control](../server/processor-control.md).

- **The hub asks, the service keeps the state.** The hub's dashboard and HTTP API (`/api/v1/services/{service}/processors/
  {processor}/...`, with the write token `SNODRA_SERVER_DASHBOARD_WRITE_TOKEN` or an ACL credential with `control = true`;
  the dashboard token only reads) send a `ControlRequest` to every instance whose status lists the processor. The state lives in the service's MongoDB, collection
  `processor_control`, one document per processor; every instance applies it before its consumer's first poll and every
  5 s, so a pause outlives every hub and restart and reaches instances that start later. Nothing to configure in either
  library.
- **Pause and resume** stop and restart consumption on every instance without leaving the consumer group (no
  rebalance); partitions assigned later stay paused. The record in hand finishes. The admin API, dead-letter retries
  and local dispatch (partner topics, webhooks, the relay's notices) still run a paused processor's handlers: pause is
  about Kafka consumption.
- **Reset** to `earliest`, `latest`, a time or explicit offsets per partition is a leased operation: every instance
  leaves the group and holds the processor's lock (a 30 s lease the hub renews every 10 s; a hub that dies lets it
  expire and the instances resume by themselves), one instance runs the reset handlers, deletes the processor's markers
  in the replay range and commits the target offsets while the group is empty, and every instance consumes again,
  still paused if it was. An instance that starts while the lock is held stays out of the group until it clears; a
  second reset is refused (`LOCKED`).
- **Replay.** A reset to anything but `latest` replays, per partition, the records from the target up to where the
  group was: the processor's event handlers run again, except the ones marked no-replay, and its sagas never do (stage
  2 is skipped for a replayed record). The reset handlers run first, once, on the executing instance, and only when the
  reset replays something; one that fails refuses the reset before any marker or offset changes (what the handlers
  that ran did stays, and the refusal says how many ran). The executor re-checks its lease after the reset handlers
  and before the commit: lost, it stops (`FAILED`, "lease lost") and says what changed. A replayed record whose key has a
  parked letter is parked `SEQUENCED` as usual, and a record parked during a replay is retried as a replay
  (`replay: true` in its letter). The status says `replaying` (`replay_until` per partition) until every
  range is passed.
- **Markers carry a position.** A Kafka record's stage-1 marker, and a dead-letter retry's, has `processor`, `topic`,
  `partition` and `offset`, so a replay deletes exactly its range: `{processor, topic, partition, offset}` per range,
  nothing else.
- **Dead letters from the hub.** List (summaries, never a payload), retry, retry all and discard, answered by one
  instance through the P6a admin API (`Retried`, `Duplicate`, `Failed`, `Blocked`, `NotRetriable`, `NotFound`).
- **Sandbox.** The `audit` processors of service-b and service-c have a reset handler (`GET /audit/resets`) and a
  no-replay notifier (`GET /audit/notified`); the examples smoke steps 27 to 27e pause, resume and reset them to
  `earliest` and work their letters through the hub with the write token, in every sandbox mode
  (`snodra-messaging/examples/README.md`).

### Reset handlers, no-replay handlers, the local API

Kotlin (`snodra-messaging`; the README's "Processor control" section is the user guide):

```kotlin
@Component
@ProcessingGroup("orders")
class OrdersProjection(private val orders: OrderRepository) {
    @EventHandler fun on(event: OrderPlaced) = orders.insert(event.toRow())

    // Once per reset that replays something, on the executing instance, before markers and offsets change; a throw fails it.
    @ResetHandler fun clear(ctx: ResetContext) {
        if (ctx.target == ResetTarget.Earliest) orders.deleteAll()
    }
}

@Component
@ProcessingGroup("orders")
class OrderMails(private val mail: Mail) {
    @DisallowReplay @EventHandler fun on(event: OrderPlaced) = mail.confirm(event)   // never again in a replay
}

// From your own code (pausedBy "local"): every instance follows the document within 5 s.
processorControl.pause("orders")
processorControl.resume("orders")
```

Rust (`snodra-messaging-rs`; the crate README's "Processor control" section is the user guide):

```rust
use snodra_messaging::processors::{EventOptions, ResetContext, ResetTarget};

let app = SnodraMessaging::builder(Config::from_env()?).await?
    .event_in::<OrderPlaced, _, _>("orders", |e, ctx| async move { insert_row(&e, &ctx).await })
    // Never again in a replay; its marker is still written.
    .event_with::<OrderPlaced, _, _>(
        EventOptions::new().processor("orders").disallow_replay(),
        |e, ctx| async move { mail_confirmation(&e).await },
    )
    // Once per reset that replays something, on the executing instance, before markers and offsets change;
    // an error (or a panic) refuses the reset before markers and offsets change (the refusal says how many ran).
    .reset_handler("orders", |ctx: ResetContext| async move {
        if ctx.target == ResetTarget::Earliest { delete_rows().await } else { Ok(()) }
    })
    .start()
    .await?;

// From your own code (pausedBy "local"): every instance follows the document within 5 s.
app.processor_control().pause("orders").await?;
app.processor_control().resume("orders").await?;
```

- **Types.** Kotlin: the annotations `@ResetHandler` (a method with no parameter or a `ResetContext`; it may suspend)
  and `@DisallowReplay` (a method, or every `@EventHandler` of a class); the beans `ProcessorControl` (the hub's
  `ControlInbound`; `pause`, `resume`) and `ProcessorControlStore` (the collection). Rust: `builder.event_with(EventOptions,
  handler)` (`event` and `event_in` are that call with default options) and `builder.reset_handler(processor, f)`;
  `processors::{ProcessorControl (pause, resume, handle), EventOptions (processor, disallow_replay)}`,
  `processors::control_store` (`ControlDocument`, `ControlStore`, `PROCESSOR_CONTROL_COLLECTION`), `hub::PROCESSOR_CONTROL`,
  `Inbound::Control`. Both: `ResetContext { processor, operationId / operation_id, target, ranges }`, `ResetTarget`
  (`Earliest`, `Latest`, `Timestamp`, `Offsets`), `ReplayRange { topic, partition, from, until }`.
- **Reset handlers** belong to their processor: Kotlin, the class's `@ProcessingGroup` (else `default`), run in bean
  registration order, then method name; Rust, the name given, run in registration order. A Kotlin reset handler in a
  processor that has no event handler on the instance never runs; in Rust it fails `start()`.
- **Pause.** Kotlin: the Spring container's `pause()` (immediate: the container keeps the rest of the poll's records in
  memory and hands them to the listener on resume). Rust: rdkafka's
  `pause` of the assigned partitions while the consumer task keeps polling; the rebalance callback pauses a partition
  assigned while paused, and a record fetched before the pause is sought back.
- **Leaving the group for a reset.** Kotlin: the processor's listener container stops (it finishes and commits the
  record in hand). Rust: the consumer task stops and its consumer is dropped on a blocking thread (librdkafka's close
  writes the commits in flight and leaves the group); the finish, or the lease expiry, creates a new consumer.
- **Reset offsets.** Kotlin, through the Kafka `AdminClient` with the consumer factory's connection settings
  (`listOffsets` for the target, `listConsumerGroupOffsets` for "before", `describeConsumerGroups` for the empty check,
  `alterConsumerGroupOffsets` for the commit). Rust has no admin call to alter a group's offsets: the executor reads the
  partitions, watermarks, `offsets_for_times` and committed offsets with a consumer of the group that never subscribes,
  checks the group empty with `fetch_group_list` (member client ids in the refusal), and commits the targets with that
  consumer; the broker refuses while the group has members (`GROUP_NOT_EMPTY`). In both an explicit offset past the
  high watermark is refused (`INVALID`).
- **Threads and tasks.** Control requests never run on the hub stream's read loop, and the reply goes to the stream the
  request came on. Kotlin: one lane per stream (in order), each processor's requests on a thread of its own. Rust: a
  task per request, the processor's lock serializing its requests and its 5 s poll. In both a lease renewal of the held
  operation is answered at once, and the executor extends its own lease (at most 120 s) while the execute runs.
- **Tests.** Kotlin: `InProcessHub.control(instanceId, request)` sends a `ControlRequest` and awaits the reply, and
  `ProcessorControlEndToEndTest` drives `snodra-server:dev` over its HTTP API. Rust: the crate's fake hub sends targeted
  control requests, and `tests/e2e_processor_control.rs` drives `snodra-server:dev` over its HTTP API.

## Wire format

### JSON payloads

Payloads are UTF-8 JSON produced by Jackson (Kotlin) or serde_json (Rust) with these rules so that
both sides agree:

- field names in `camelCase`;
- timestamps as ISO 8601 strings in UTC (`2026-10-28T14:03:22Z`);
- ids as strings (UUID or ULID);
- unknown fields ignored on read (`FAIL_ON_UNKNOWN_PROPERTIES=false`, `#[serde(default)]`), so
  adding optional fields is backward compatible;
- never rename or remove a field without introducing a new message type.

The `*-api` module of the owning service is the authoritative schema for JVM consumers. For the Rust
service the shapes are documented in [05-services/the service.md)
and mirrored as serde structs.

### Events on Kafka

| Record part | Content |
|---|---|
| topic | `snodra.events` |
| key | aggregate id (string) chosen by the publisher; guarantees ordering per aggregate |
| value | JSON payload |
| header `type` | wire type name, for example `billing.WorkoutLogged` |
| header `id` | event id (UUID), used for idempotency |
| header `correlationId` | propagated from the originating request, new UUID if absent |
| header `timestamp` | ISO 8601 UTC, when the event was created (not when sent) |
| header `source` | publishing service name |
| header `userId` | the OAuth2 subject of the acting user, empty for system events |
| header `traceparent` | W3C trace context |

Only `userId` crosses into events; the JWT itself never does, because events are consumed later
and by many parties.

### Commands and queries over the hub

The gRPC `Request` message from ``protocol/hub.proto`` carries `type`,
`routing_key`, the JSON `payload`, and `headers` with:

| Header | Content |
|---|---|
| `authorization` | `Bearer <JWT>` of the acting user, forwarded from the inbound HTTP request |
| `correlationId` | same as above |
| `traceparent`, `tracestate` | W3C trace context |

The handling service validates the JWT exactly as it validates a REST request (issuer, signature via
JWKS, expiry, required realm role). See 06-security.md.

## Kafka layout

| Setting | Value |
|---|---|
| Topic | `snodra.events` |
| Partitions | 6 |
| Retention | 30 days (`retention.ms=2592000000`) |
| Cleanup policy | `delete` |
| Replication | 1 (single broker) |
| Producer | `acks=all`, `enable.idempotence=true`, key = aggregate id |
| Consumer group | `<service group>.<processor>` for every processor, `default` included, the service group being `snodra.messaging.kafka.group-id` or the service name (Rust: the service name) (P6a, [Event processors and dead letters](#event-processors-and-dead-letters)); all instances share them |
| Offset commit | after the handler's transaction commits (manual ack) |

Why one topic: ordering per aggregate across event types, a single place to look, and a single
subscription per service; consumers skip records whose `type` they do not handle. Trade-off: every
service reads every event. At Snodra's scale this is
negligible; if it ever matters, per-service topics are the escape hatch recorded in
ADR 0003.

Replay: reset the consumer group's offsets (`kafka-consumer-groups.sh --reset-offsets`) while the
service is stopped. The `processed_events` collection must be cleared for the same service when a
true re-processing is intended, otherwise the replayed records are skipped as duplicates.

## Outbox and idempotency

### Collections (per service database)

`outbox`

```json
{
  "_id": "uuid",
  "type": "billing.WorkoutLogged",
  "key": "workout-123",
  "headers": { "correlationId": "...", "userId": "...", "traceparent": "..." },
  "payload": { "...": "..." },
  "createdAt": "2026-10-28T14:03:22Z",
  "seq": 42,
  "sentAt": null,
  "attempts": 0
}
```

`seq` is monotonic per publishing instance and breaks `createdAt` ties. Index:
`{ sentAt: 1, createdAt: 1, seq: 1 }`, TTL on `sentAt` for the retention period. Per-key ordering is
guaranteed per publishing instance only.

`processed_events`

```json
{ "_id": "<event id>", "type": "files.FileDeleted", "processedAt": "2026-10-28T14:03:23Z" }
```

TTL index on `processedAt`.

### Publisher

Each service instance runs an `OutboxPublisher`. Every `poll-interval` it claims up to `batch-size`
documents with `sentAt == null` ordered by `createdAt` then `seq`, produces them to Kafka with the stored key and
headers plus `type`, `id` (= `_id`), `timestamp` (= `createdAt`) and `source`, and sets `sentAt` after
the broker acknowledges. Multiple instances compete; a document may be sent twice if an instance
dies between produce and update. That is acceptable because consumers are idempotent.

> no leader election for the publisher. Duplicates are already handled by
> consumers and the simplicity is worth more than exactly-once sending.

### Consumer

For each record: skip if `type` has no handler and no saga reacts to it (commit offset). Otherwise open a Mongo transaction,
insert `processed_events{_id = header id}`; if that insert fails with a duplicate key, skip and commit
the offset. Otherwise invoke the handler inside the same transaction, commit, then commit the offset.
A handler exception rolls back both and the record is retried with backoff; after
`snodra.messaging.kafka.consumer.max-attempts` (default 5) the record is logged and skipped, with
the offset committed.

Handlers run inside the Mongo transaction on the listener thread. A handler that relies on the
transaction must not switch threads.

In a service with sagas the same record then goes to its saga types, each in a transaction and with a marker of its own,
before the offset is committed; see [Delivery and consistency](#delivery-and-consistency).

> **Builder call (first version):** no dead-letter topic; failed records are visible as metrics
> and logs in Grafana. **Reversed by ADR 0022**
> (P6a, built in both libraries): a record that exhausts its attempts is parked as a dead
> letter by default, see [Event processors and dead letters](#event-processors-and-dead-letters).

## Hub protocol walkthrough

Reference: ``protocol/hub.proto``, hub internals in
[05-services/hub.md](../server/index.md).

1. **Connect.** At startup each instance opens `Hub.Connect` (HTTP/2 keepalive 10 s / 5 s, also
   while idle) and sends `Register{service_name, instance_id, command_types, query_types,
   initial_permits, client_version, credentials}` (the token or JWT, when configured) followed by a `Heartbeat`. The
   hub records the instance and answers with `RegisterAck{hub_id, heartbeat_interval_ms, heartbeat_timeout_ms,
   default_timeout_ms, max_timeout_ms, type_timeouts_ms, ...}` before the echo of that heartbeat. The ack is the
   confirmation that the `Register` was processed: a stream without one within 10 s fails with `DEADLINE_EXCEEDED`
   ("registration not confirmed in time") and the client reconnects. The hub and the libraries ship together, a hub
   and a client of different builds are not supported (ADR 0024).
2. **Heartbeat.** The client heartbeats at the interval from the ack (3 s by default); the hub echoes it with
   `sent_at_ms` unchanged. Silence for the hub's heartbeat timeout (10 s) or a closed stream removes the instance and fails its in-flight requests with `HANDLER_DISCONNECTED`. A
   client that gets no echo for three intervals drops the stream and reconnects.
3. **Send.** `CommandBus.send` builds `Request{id, kind, type, routing_key, payload, headers,
   timeout_ms}` and writes it to the stream, then awaits a `Reply` or `Error` with the same id.
   `timeout_ms` is 0 unless the caller chose a timeout, so the hub's default or per-type override
   applies; the client gives up locally after the hub's bound for the type plus 1 s.
   `Request.id` is a fresh UUID per send attempt. The identifier a handler uses to detect a retried
   command is the aggregate or command id inside the payload, never `Request.id`; a retry that
   reused `Request.id` while the first attempt is still pending is rejected with `INVALID_REQUEST`.
4. **Route.** The hub looks up the type. No owner: `Error{NO_HANDLER}` back to the sender. Owner
   found: pick an instance (commands: consistent hash of `routing_key`, round-robin when empty;
   queries: round-robin) and forward the `Request` unchanged.
5. **Handle.** The receiving library validates the JWT, deserialises the payload to the handler's
   parameter type, invokes it, and writes `Reply{request_id, payload}` or `Reply{request_id,
   error}`.
6. **Relay.** The hub forwards the `Reply` to the sender's stream. If the deadline passes first it
   sends `Error{TIMEOUT}` to the sender and drops any late reply.
7. **Reconnect.** When the stream drops, requests written to it fail with
   `HubConnectionLostException` (outcome unknown) and the client reconnects with exponential
   backoff (500 ms to 5 s, ±20 % jitter, reset once an attempt reached the handshake) and re-sends
   `Register`. Requests issued while disconnected fail with `HubUnavailableException` (never
   sent): the Kotlin starter first waits up to the request timeout (5 s when unset) for a stream,
   the Rust crate fails at once until the new stream completed its handshake.

### Error semantics summary

| Code | Produced by | Sender sees | Retry advice |
|---|---|---|---|
| `NO_HANDLER` | hub | `NoHandlerException` | Retry later; owning service is probably starting |
| `TIMEOUT` | hub or client | `MessageTimeoutException` | Commands: check idempotency before retrying; queries: retry |
| `HANDLER_DISCONNECTED` | hub | `HandlerDisconnectedException` | Same as timeout |
| `HANDLER_ERROR` | handler | `RemoteHandlerException` | Application decides |
| `UNAUTHENTICATED` | handler; hub (a request after the token left the ACL: `Error`; a `Register` with no or an unknown token: closed stream) | `UnauthenticatedException`; on a closed stream a registration rejection (`HubRegistrationRejectedException` from `awaitRegistered`, Rust `await_hub` false) | Do not retry; no identity, or the user's token is invalid or expired, or fix the service's hub token |
| `PERMISSION_DENIED` | handler; hub (a request outside the token's `send`: `Error`; a `Register` for a service name or handled type the token does not grant: closed stream) | `AccessDeniedException` / `MessagingError::AccessDenied`; on a closed stream a registration rejection | Do not retry; the caller lacks the role or ownership the handler requires, or the ACL does not list the type (fix the ACL's `send` / `handle`) |
| `INVALID_REQUEST` | handler (a bad payload, or the wrong mode for its handler: a unary query to a streaming or subscription handler, a stream to a unary one), or hub for malformed/duplicate requests and a stream part without credit | `InvalidMessageException` / `MessagingError::InvalidMessage` | Do not retry; contract mismatch, check api module versions (or the call: `send` vs `stream`) |
| (no code: request never written) | client | `HubUnavailableException` / `MessagingError::HubUnavailable` | Retry; the handler never saw it |
| (no code: stream lost after the write) | client | `HubConnectionLostException` / `MessagingError::HubConnectionLost` | Same as timeout: the outcome is unknown |
| `RESOURCE_EXHAUSTED` | hub (queue or buffer full), or a subscription's buffer overflow or limit (hub or handler instance) | `HandlerBusyException` / `MessagingError::HandlerBusy` | Retry with backoff; the handler never ran |
| `CANCELLED` | hub: a streaming query outlived `SNODRA_SERVER_MAX_STREAM_DURATION`, or a subscription `SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION` | `StreamCancelledException` / `MessagingError::Cancelled` | Do not retry; the parts received stay valid, open a new stream for the rest |

How fast each of these surfaces when the owning service is stopped, killed or partitioned, and
the planned improvements, are documented in
[05-services/hub.md](../server/limitations.md).

Commands are not durable anywhere. A `TIMEOUT` does not tell the sender whether the handler ran.
Command handlers should therefore be idempotent on their aggregate id, and senders should reuse the
same business command id (the id inside the payload, not the transport `Request.id`) on retry so the
handler can detect duplicates.

## Testing support

`com.damoreira.snodra:snodra-messaging-test` provides:

- `InMemoryBuses`: `EventBus`/`CommandBus`/`QueryBus` for unit tests that never leave the JVM; a
  subscription query answers its initial result from the registered handler and takes its updates
  from `buses.emitter`, a local `QueryUpdateEmitter` (no credits, delivered at once).
- `InProcessHub`: an in-JVM hub for tests.
- `SnodraContainers`: Testcontainers 2.0.5 helpers `kafka()` (`apache/kafka:4.4.0`), `mongo()` (a
  replica set), `hub()`, `hubAcl(...)`, `hubJwt(...)`, `hubMtls(...)` (the hub with access control) and
  `hubImageAvailable()`, all on the image under test.
- `SnodraTestKafka(bootstrap, topic, typePrefix)`: reads events from the events topic.
- `SagaTestFixture(SagaClass::class, beans…)`: drives one saga with events and time, in memory, on the library's own saga runtime
  (see [Sagas and deadlines](#sagas-and-deadlines)): `givenEvents`, `givenCurrentTime`, `whenEvent(event, headers)`,
  `whenCommandFailed(command, reason, message)`, `whenTimeElapses(duration)`, `expectActiveSagas`, `expectAssociation`,
  `expectDispatchedCommands`, `expectPublishedEvents`, `expectScheduledDeadline`, `expectNoScheduledDeadlines`,
  `expectSagaEnded`. Every step encodes and decodes the saga state as JSON (a state the codec cannot carry fails the step), a
  handler that throws leaves nothing behind, and the dispatch expectations cover what was sent since the last `given…` step.

The Rust crate has its saga fixture in the crate itself, behind the cargo feature `testing`
(`snodra-messaging-rs = { path = "..", features = ["testing"] }` under `[dev-dependencies]`):
`snodra_messaging::saga::testing::SagaTestFixture::new(name, define)` takes the closure given to `builder.saga` and has the same
steps and expectations in snake case (`given_events(&[&e1, &e2])`, `when_event`, `when_event_with_headers`,
`when_command_failed`, `when_time_elapses`, `expect_*`), over the crate's runtime and the in-memory ports `InMemorySagaStore`.
Its methods are synchronous and **panic** on a failed step or expectation (naming the saga), as a Rust test expects.

> `hub()` uses the image `snodra-server:dev` locally (override with
> `SNODRA_SERVER_IMAGE`), not the registry name. The end-to-end test is skipped when the image is
> absent (`hubImageAvailable()`).

See [09-observability-and-testing.md](../server/observability.md).

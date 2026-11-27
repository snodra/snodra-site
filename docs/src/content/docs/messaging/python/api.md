---
title: "API"
---

The package is `snodra`, installed via `pip install snodra-messaging`. This page is the tour of the API.

## Messages

A message is a dataclass (or Pydantic model) decorated with `@snodra.message_type("...")`, which specifies the type name
every handler registers for and every sender addresses, for example `orders.PlaceOrder`. The payload is JSON
(`JsonCodec`, unknown fields ignored on read), the same JSON every Snodra library reads and writes; `Codec` changes the
codec, and only a codec that writes the same JSON keeps the services of other languages working. A result type is any
class, or `None` (which answers `{}`).

## Handlers

`@app.command_handler`, `@app.query_handler`, `@app.stream_handler` and `app.subscription_handler` register a handler for
a type on the `snodra.App`. Handlers are registered before `app.start()` (or `run()`). Registering after startup raises
`snodra.RegistrationClosed`.

- A handler runs in an asyncio task that is cancelled when the hub cancels the request (the caller gave up, or the request
  timed out). A handler that ignores cancellation keeps its permit and its concurrency slot until it returns.
- Handler code must never block the event loop: run blocking synchronous work in `asyncio.to_thread`.
- An unhandled exception in a handler is caught and answered as `HANDLER_ERROR` with a safe message.
- `max_concurrent` handlers run at once; further requests wait at the hub.

### Handler errors

A handler's error is answered `HANDLER_ERROR` unless it was raised with `snodra.Unauthenticated`,
`snodra.PermissionDenied` or `snodra.InvalidRequest`, which answer `UNAUTHENTICATED`, `PERMISSION_DENIED` and
`INVALID_REQUEST`. Raising `snodra.HandlerError(message, details={...})` attaches machine-readable details (JSON),
which only a `HANDLER_ERROR` carries.

### Guards

```python
# An anonymous caller is refused before the payload is decoded; a guard needs Settings.jwks_url.
@app.command_handler(guard=snodra.role("orders-admin"))
async def archive_order(cmd: ArchiveOrder) -> None:
    caller = snodra.current_caller()
    print("archived by", caller.subject if caller else "unknown")
```

`authenticated()`, `role()` and `caller_matches()` answer an anonymous caller `UNAUTHENTICATED`, before the payload is
decoded, and a caller they refuse `PERMISSION_DENIED`, once the payload is decoded. Every guard needs `jwks_url` and
`issuer` in `Settings`: registering a guarded handler without them raises `ConfigurationError`.

`@app.query_handler(shared=True)` registers a query type as shared: many services may own it, and a `gather` asks every
instance of every owner. Every owner must register it shared. `@app.stream_handler(shared=True)` shares a streaming type
the same way (its name goes to `Register.shared_query_types`): many services may own it, and a `stream` goes to one live
instance that owns it; a point query of the type is still refused with `INVALID_REQUEST`.

## Sending

Any service, including one that owns no handler, sends with `send` (a command, to the one instance that handles its
type) and `query` (a point query):

```python
receipt = await app.send(
    PlaceOrder(order_id="o-1", items=[Item(sku="sku-1", quantity=2)]),
    OrderReceipt,
    routing_key="o-1",
    timeout=3.0,
)

order = await app.query(
    GetOrder(order_id=receipt.order_id),
    Order,
)
```

The options of a call:

| Option | Meaning |
|---|---|
| `timeout` | this call's timeout in seconds, sent as `Request.timeout_ms`; wins over `default_timeout`; with none, the hub applies the type's own timeout or its default |
| `routing_key` | commands of one type with the same key go to the same instance of the owning service, typically the aggregate id; queries, streams and gathers ignore it |
| `priority` | the request's priority (an integer), higher first while the target's queue at the hub is not empty; wins over `priorities` |
| `headers` | adds headers, which the handler sees in `MessageInfo.headers`; the names the library sets itself (`authorization`, `traceparent`, `tracestate`, `correlationId`, `correlation-id`, in any letter case) raise `ReservedHeader` |
| `retry` | this call's retry policy (`RetryPolicy(...)` or `False` for no retry); wins over `default_retry` |
| `initial_credit` | the credit window of a `stream` or `subscribe` (default 64) |
| `max_results` | ends a `gather` after `n` successful parts, a `stream` after `n` items, a `subscribe` after `n` updates |

A request sent while a handler runs carries that request's correlation id, its caller's token (see `forward_jwt`) and
its trace context. Outside a handler it carries a new correlation id.

While no hub can take a request (none connected yet, a hub restarting), the call waits for one within its timeout (5 s
without one), and only then fails with `NeverSent`. One deadline bounds the call: a request moved to another hub sends
its full timeout again, and no new hub is tried once that deadline has passed.

### Requests answered in-process

A command, or a query that is not shared, of a type this instance handles itself is answered in-process: its handler
runs on the caller's task with no hub, no permit and no handler slot, also before `start`; once `shutdown` has drained the
handlers, such a call fails as `NeverSent` instead. It sees a fresh request id, the caller's `headers` and the
correlation id, and acts for the caller the hub path would carry
(the handled request's caller when `forward_jwt` is on; anonymous outside a handler or with it off). The routing key,
timeout, priority and retry do not apply, no request metric is recorded (the handler's span still is), and its errors
are those a hub would have relayed.
Setting `always_route_through_hub=True` (`SNODRA_SERVER_ALWAYS_ROUTE_THROUGH_HUB=true`) sends every request through a
hub, so a routing key keeps its instance affinity across the instances of the service. `gather`, `stream` and
`subscribe` always go through a hub.

### Retries

Retries are opt-in: `Settings(default_retry=RetryPolicy())` for every call, or `retry=RetryPolicy(...)` per call. The
default policy is 3 attempts, 100 ms doubling up to 2 s, each wait jittered by +/-20 %. A command is retried only when
its handler never ran (`NeverSent`, `NO_HANDLER`, `RESOURCE_EXHAUSTED`); a query is also retried after an unknown outcome
(`OutcomeUnknown`, `TIMEOUT`, `HANDLER_DISCONNECTED`). Every attempt has a fresh request id and all attempts share one
time budget.

## The four query modes

| Mode | Asking | Serving | Answer |
|---|---|---|---|
| point | `query` | `@app.query_handler` | one result from one instance |
| scatter-gather | `gather` | `@app.query_handler(shared=True)` | the answers of every instance of every owner |
| streaming | `stream` | `@app.stream_handler` | many items, under the caller's credit |
| subscription | `subscribe` | `app.subscription_handler` | an initial result, then updates until it is closed |

```python
# Serving a stream: an async generator whose yielded items go out under the caller's credit.
@app.stream_handler
async def list_orders(q: ListOrders):
    for r in [OrderReceipt("o-1", 1250), OrderReceipt("o-2", 80)]:
        yield r

# Reading one: leaving the async with block cancels the stream at the hub.
async with app.stream(ListOrders(), OrderReceipt) as items:
    async for r in items:
        print(r.order_id, r.total)

# Asking every instance of every owner of a shared query type.
gathered = await app.gather(GetOrder("o-1"), Order, timeout=2.0)
print(len(gathered.parts), "answers from", gathered.targets, "targets")
```

- **Gather.** Partial answers are answers: a gather where some targets failed or timed out still succeeds, and
  `Gathered` says what was missing (`parts`, each with its `service`, `instance`, `value` or `error`; `failed`;
  `timed_out`; `targets`). `timeout` is the deadline of the whole gather.
- **Stream.** `async with app.stream(...) as items:` opens the stream, and `async for item in items:` reads each part.
  Leaving the block early, an item that does not decode, lost parts and task cancellation cancel the stream at the hub,
  so credit and tasks are released. A stream is retried only until its first item; after that nothing is retried, and a
  lost hub stream raises `OutcomeUnknown`. A handler waiting for credit longer than `stream_credit_timeout` (10 minutes)
  is ended with `TIMEOUT` and cancelled.
- **Subscribe.** Updates are hot: the hub relays them from the open on, up to the credit window.

```python
# Serving a subscription: the decorated name is the Updates that pushes to the open subscriptions.
@app.subscription_handler(update=OrderStatus)
async def watch_order(q: WatchOrder) -> OrderStatus:
    return OrderStatus(status="placed")

# emit, complete and fail run on the app's event loop
watch_order.emit(lambda q: q.order_id == "o-1", OrderStatus(status="shipped"))

# Following one:
async with app.subscribe(WatchOrder("o-1"), OrderStatus, OrderStatus) as sub:
    print("initial:", sub.initial.status)
    async for u in sub:
        print("update:", u.status)
```

`app.subscription_handler(...)` is a decorator whose result is the `Updates[Q, U]` bound to the handler's name:
`emit(match, update)` reaches every open subscription whose match function returns `True` and returns how many it
reached; `complete(match)` and `fail(match, error)` end them. `emit`
runs on the app's event loop. A subscription takes no permit and no handler slot, bounded by `max_subscriptions`. The
`async with` block bounds the whole subscription: when it exits, the subscription is cancelled at the hub.

## Errors

A failed call raises one of:

| Error | Meaning |
|---|---|
| `HubError` | the hub's or the handler's answer, with `code` (`NO_HANDLER`, `TIMEOUT`, `HANDLER_DISCONNECTED`, `HANDLER_ERROR`, `UNAUTHENTICATED`, `INVALID_REQUEST`, `PERMISSION_DENIED`, `RESOURCE_EXHAUSTED`, `CANCELLED`), `message` and optional `details` (the handler's JSON, as bytes) |
| `NeverSent` | the request was written to no hub within the call's timeout (5 s without one): sending it again is safe |
| `OutcomeUnknown` | the request was written and no answer arrived: the handler may or may not have run |
| `LostParts` | a stream or gather lost parts that were already announced |
| `ReservedHeader` | a header name the library sets itself; nothing was sent |
| `DecodeError` | the payload could not be decoded as the requested result class |
| `asyncio.CancelledError` | the calling task was cancelled |

The library's own `TIMEOUT` is raised as `HubError` when no answer came within the hub's bound for the request plus 1 s.

## Identity

`snodra.current_caller()` returns the verified caller of the request being handled: `Caller(subject=..., roles=...)`.
It returns `None` for an anonymous caller and outside a handler. Without `jwks_url` and `issuer` in `Settings`, no
token is an identity: every caller is anonymous. A header that is not a bearer token, or a token that is not a signed
JWS, is answered `UNAUTHENTICATED` before the handler is looked up.

`snodra.current_message()` returns the current `MessageInfo(id=..., type=..., correlation_id=..., headers=...)`.
`roles_claim` sets where roles are read in the token, and `forward_jwt` controls whether outgoing requests carry the
handled request's token.

## Lifecycle

`snodra.App(settings)` builds an application and connects to nothing; it fails on missing or invalid settings. Then:

- `await app.start()` opens a connection to every hub and returns at once; each registers and reconnects on its own.
  No handler can be registered after it.
- `await app.ready(timeout=None)` waits until a hub has acknowledged the registration.
- `await app.run()` starts, serves until SIGTERM or SIGINT (or task cancellation), then shuts down within 15 s.
- `await app.shutdown(timeout=15.0)` leaves the hubs in order: an empty registration so requests route elsewhere at
  once, then ends every subscription served here, then drains handlers in flight (at most 5 s), then half-closes each
  stream. A handler that ignores cancellation outlives `shutdown`: the library cannot force a task to stop, so it
  logs a warning and stops waiting for it.
- `async with app:` starts the app on entry and shuts it down on exit.
- `app.hub_ids()`, `app.rejection` and `app.subscriptions_served` report the state of the connections.

### Several hubs

An instance opens one stream to every hub it is given, each with the identical registration, and knows a hub by its
`RegisterAck.hub_id`. A second address that answers a hub id already served is parked and takes over if the first goes
away. With one `dns:///name:port` target, every address is a hub, resolved again every 30 s: an address that leaves the
answer is drained and closed, a new one is connected.

A unary request a hub answers `NO_HANDLER` goes to the other live hubs in turn, with the same id and its full timeout;
a hub that declined or did not take the request is not tried again in the same call. When every live hub declined, the
last `NO_HANDLER` is the answer at once; when the call's deadline passes with a live hub still untried, it fails with
`NeverSent`. Without a routing key, the next untried hub is picked as `untried[shared_counter % len(untried)]`, one
counter shared by every call.

## Telemetry

The core only defines an interface (`snodra.Telemetry`) and defaults to `snodra.NoTelemetry()`. The separate package
`snodra-messaging-observability` implements it on the OpenTelemetry API:

```python
from snodra_observability import Observability

app = snodra.App(
    settings,
    telemetry=Observability(),  # uses the global providers; or meter_provider, tracer_provider, propagator
)
```

```sh
pip install snodra-messaging-observability
```

One `Observability` serves one `App`. The metrics have the names and labels of the Kotlin, Rust and Go libraries, so
one dashboard serves every library.

| Instrument | Kind | Labels |
|---|---|---|
| `snodra.hub.client.request.duration` | histogram, s | `kind`, `type`, `outcome` |
| `snodra.hub.client.handlers.in.flight` | gauge | |
| `snodra.hub.client.connected.hubs` | gauge | |
| `snodra.hub.client.token.fetches` | counter | `result` |
| `snodra.hub.client.certificate.rotations` | counter | |
| `snodra.hub.client.credentials.refreshes.sent` | counter | |

The request duration covers a `send` or `query` from the call to its result, retries included; a call its caller cancels,
a call its options refuse and a call answered in-process record no metric. The instrumentation scope is `snodra`. A request
a handler serves gets a server span named after the message type, a child of the request's `traceparent`, and the requests
the handler sends carry its trace context.

## Events

An event is a message type like a command or a query: a class decorated with `@snodra.message_type("...")` (a
dataclass or Pydantic model), whose payload is serialized as a JSON object. `app.publish` builds it and appends it to
the service's outbox, for example
`await app.publish(OrderPlaced(order_id=cmd.order_id, total=cmd.total), key=cmd.order_id)`.

`publish` needs the message store and the event store ([Add-ons](#event-stores-and-message-stores)); without them the
first call raises `ConfigurationError`, naming the missing add-on. It returns once the entry is appended, not when the
event reaches the event store. The event's type is the class's `@message_type` name, its id a fresh UUID, its timestamp
the creation time in UTC, and `key` is its order key (an empty key is a key; without `key` the event has none). A
payload that is not a JSON object, or that is invalid, raises `InvalidMessage` and nothing is appended.

### Event headers

Every published event carries the first six headers; `traceparent` is added when the work that published it carries a
trace context. `publish` stores the correlation id, the user id and the trace context in the outbox; the relay adds
the type, id, timestamp and source from the entry, so a store never holds a stale copy of them.

| Header | Content |
|---|---|
| `type` | the event's type name, for example `orders.OrderPlaced` |
| `id` | the event's id (a UUID): the key of every duplicate check |
| `correlationId` | the correlation id of the message being handled when the event was published; a new UUID when there is none |
| `timestamp` | when the event was created, RFC 3339 in UTC with milliseconds (`2026-10-28T14:03:22.000Z`) |
| `source` | the publishing service's name, not the event store's source |
| `userId` | the acting user's id: the verified caller's subject, or the userId of the event being handled; empty for a system event. A token never crosses into an event |
| `traceparent` | the W3C trace context of the work that published it, when that work carries one |

`snodra.EventHeaders` lists the seven names in order. Outside any handling an event has no traceparent and its
correlation id is a fresh UUID.

### The outbox and the relay

`publish` appends in the transaction bound to the current context: the one `async with store.transaction():` began,
the service's own transaction bound with the SQL add-on's `conn=` or the MongoDB add-on's `session=`, or a short
transaction of its own when no transaction is bound. A rolled-back transaction leaves no event. A committed one leaves
an entry the relay will publish.

Every instance runs one relay unless `Settings(outbox_enabled=False)` (`SNODRA_OUTBOX_ENABLED=false`):

- **Claimed under a lease.** A relay claims pending entries in `(created_at, seq)` order, up to the batch size, and
  holds them for the lease (`SNODRA_OUTBOX_LEASE_MS`, 2 minutes by default). A crashed relay's entries are claimed
  again once its lease has passed; nothing is lost.
- **Sent one after the other.** The relay publishes an entry, then marks it sent. A crash between the two publishes
  the event again after the lease, and consumers skip the duplicate by its marker.
- **Order per key, per relay.** Events with one key reach the event store in publish order while one relay sends
  them. Several relays can claim different batches, so batches of different instances are not ordered against each
  other; run the relay on one instance (`Settings(outbox_enabled=False)` on the others) when the order of everything one
  instance publishes must hold.
- **Failures.** An event the store rejects for good (`Rejected`) is given up at once; another failure counts an
  attempt and ends the batch, so the next claim retries that entry before the later ones. After
  `SNODRA_OUTBOX_MAX_ATTEMPTS` sends the entry is marked failed and logged.

### Event handlers

`@app.event_handler` registers a handler of the event type annotated on its first parameter;
`@app.event_handler(processor="...")` puts it in a named processor. As for the other handlers, registration happens
before `start` (or `run`) and an error is raised at once or during startup.

A handler runs inside the processor's transaction, together with the event's processed-event marker:

1. the store records the marker (`processor:<processor>:<eventId>`) in a transaction;
2. a marker that exists already means the event is a duplicate: no handler runs and the record is acknowledged;
3. every handler of the type, in registration order, runs in the same transaction (an error in one fails the record);
4. the transaction commits, and only then the record is acknowledged.

So the handler's own writes and the marker commit together, and a record that comes again after a crash is skipped
instead of handled twice. An event type the processor has no handler for is acknowledged and runs nothing; a record
without a type header, or whose payload is not a JSON object or does not decode as the handler's type, is logged and
acknowledged. A handler that fails is tried up to `SNODRA_CONSUMER_MAX_ATTEMPTS` times (5 by default), the first
included, one second apart; after that the next release makes the record a dead letter in the `collection` mode, the
default ([Configuration](/docs/messaging/python/configuration/#dead-letters-level-3-in-progress)); the latest level-2
release logged and skipped it. A subscription that fails is reopened after 1 s, doubling up to 30 s, and the wait
starts over after a delivery or a subscription that lived 30 s.

An event handler has no caller: `current_caller()` is `None` (an event carries a user id, never a token).
`current_message()` returns the event's id, type, correlation id and headers. What the handler publishes carries that
correlation id, that user id and its trace context.

### Processors

| Processor | Registered with | Subscription | Markers |
|---|---|---|---|
| `default` | `@app.event_handler` without `processor` | `<service>.default` | `processor:default:<eventId>` |
| `<name>` | `@app.event_handler(processor=name)` | `<service>.<name>` | `processor:<name>:<eventId>` |

A processor name matches `[a-z0-9][a-z0-9-]{0,47}` (at most 48 characters) and is never `default`. One event type in
two processors reaches both, each in its own transaction and marker family: a failure in one does not affect the
other. Every instance of a service that registers a handler for a processor reads that subscription; the instances
share its segments, so a segment is read by one instance at a time.

**A new processor reads from the beginning of what the event store keeps.** Moving a handler from `default` to a
named processor, or adding a handler of an event type that has history, runs it over every event still in the store's
retention: the new subscription and its marker family are new. That is what a projection wants when it can rebuild;
a handler with effects outside the database repeats every one of them. Leave such a handler in `default`, or move the
new subscription to the end of the source before you deploy it with the event store's own tooling (for Kafka, reset
the consumer group `<service>.<name>` to `latest` while it has no member).

`Settings(consumer_enabled=False)` (`SNODRA_CONSUMER_ENABLED=false`) stops the instances reading event subscriptions,
for a tool that only publishes.

## Event stores and message stores

The two stores are add-ons: the core ships neither and imports neither. A service passes one of each to `App`, with
`store=` and `event_store=`:

```python
app = snodra.App(settings, store=store, event_store=event_store)
```

| Add-on | Package | Interface |
|---|---|---|
| Kafka | `snodra-messaging-kafka` | event store (`KafkaEventStore`) |
| RabbitMQ Streams | `snodra-messaging-rabbitmq` | event store (`RabbitMQEventStore`) |
| MongoDB | `snodra-messaging-mongo` | message store (`MongoStore`) |
| SQL (PostgreSQL, MySQL) | `snodra-messaging-sql` | message store (`SqlStore`) |

The event-store interface expects one subscription per processor, competing instances sharing its segments, order per
key, at-least-once delivery with acknowledgement, pause and resume, and the headers as the store's native metadata. The
message-store interface is frozen at level 2: its outbox and processed-event ports are implemented by both official
stores, and the dead-letter, processor-control, external-call and saga ports raise `MessageStoreUnsupported` at level 2
(the official add-ons implement every port by level 4). A third-party add-on implements the same interfaces and depends
on the core only; `snodra.testing` is its conformance kit (see [Testing](/docs/messaging/python/testing/)).

`App.start` hands the message store the application's clock, then prepares its schema (`init_schema`) or, with
`SNODRA_STORE_INIT_SCHEMA=false`, checks it (`check_schema`); a failure fails `start`. A store that also implements
`StoreLifecycle` starts its own background work there (the SQL add-on's purge, for example). A publish or an event
handler without the two stores fails: an event handler at `start`, naming the missing add-on, and a publish at its
first call, because a service that only publishes cannot be told apart at build time.

The in-memory stores, `snodra.MemoryEventStore()` and `snodra.MemoryStore()`, are not durable and are for tests and
local runs; `start` warns once for each. The [add-ons pages](/docs/add-ons/) list the artifacts, settings,
guarantees and capabilities of each store.

### Transactions and context binding

A message store implements `async with store.transaction():`. `publish` and the consumer's marker use the transaction
bound to the current task context; the service's own writes join it through the store's transaction helpers:

- **SQL.** `async with store.transaction():` begins a transaction (at READ COMMITTED) and binds it.
  `store.transaction(conn=conn)` binds a connection the service began (an `asyncpg.Connection` or `asyncmy`
  connection). A pool with at least two connections is required; the default is ten.
- **MongoDB.** `async with store.transaction():` runs on a session transaction. `store.transaction(session=session)`
  binds a session the service began. `store.session(tx)` or `store.session()` returns the `AsyncClientSession` of the
  current transaction. The database must be a replica set.

Transactions are managed across async tasks using Python's `contextvars`:
- `snodra.bind_transaction(tx)` binds a `Tx` to the current task context, returning a token.
- `snodra.current_transaction()` returns the currently bound `Tx`, or `None`.
- `snodra.unbind_transaction(token)` restores the previous binding.

Outside any transaction, a store call runs in a short transaction of its own.

### Event errors

| Error | Meaning |
|---|---|
| `Invalid` / `InvalidMessage` | the event or a store argument is invalid: a payload that is not a JSON object, an integer too large, a missing setting. Nothing was appended |
| `Rejected` | the event store will never take the event; the relay gives it up at once |
| `Failed` / `MessageStoreFailed` | the store failed; another try may succeed, and the relay retries within its attempts |
| `Conflict` | another writer got to the record first; the caller retries the operation as a whole, in a new transaction |
| `Unsupported` / `MessageStoreUnsupported` | the port or the operation is not implemented at this level |

## Not in the Python library yet

Sagas (feature level 4) are not in the Python library. The level-3 APIs — processor status and control (pause, resume,
reset and replay), dead letters, `@app.reset_handler` and `ResetContext` — are implemented and are documented with the
level-3 release. The library has no event browser either, so its event-store add-ons declare no `browse` capability. For
sagas, use the [Kotlin](/docs/messaging/kotlin/) or [Rust](/docs/messaging/rust/) library.

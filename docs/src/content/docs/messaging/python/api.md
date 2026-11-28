---
title: "API"
---

The package is `snodra`, installed via `pip install snodra-messaging==0.8.0`. This page is the tour of the API.

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
pip install snodra-messaging-observability==0.8.0
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
instead of handled twice. An event type the processor has no handler for is acknowledged and runs nothing. A record
without a `type` header, or whose payload is not a JSON object for a type the processor handles, can never be handled:
in mode `collection` it is parked as an `INVALID` letter, in `event-store` it is published to the dead-letter source,
and in `log` it is logged and skipped. A payload that does not decode as the handler's type is not retried either: in
`collection` it is parked as a `HANDLER_FAILED` letter with `InvalidMessage` as its error type, and in the other modes
it is published or logged like any other exhausted record. A handler that fails is tried up to
`SNODRA_CONSUMER_MAX_ATTEMPTS` times (5 by default), the first included, one second apart; after that the record
becomes a dead letter, according to [`dead_letter_mode`](#dead-letters). A subscription that fails is reopened after
1 s, doubling up to 30 s, and the wait starts over after a delivery or a subscription that lived 30 s.

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

## Processor status

Every status report (`SNODRA_SERVER_STATUS_INTERVAL_MS`, 5 s by default) carries one `ProcessorStatus` per processor
that has started on this instance, and the whole list every time. The status is built from memory and never waits on
the event store, the message store or a handler, so it cannot delay a tick or a consumer. The hub shows it in its
topology, `GET /api/v1/processors` and the dashboard's Processors page; this library has no local status method.

| Field | Content |
|---|---|
| `name`, `subscription`, `source` | the processor, its subscription `<service>.<processor>`, and the event store's source |
| `state` | `PROCESSOR_STOPPED` while its consumer does not run (stopping, or out of its subscription for a reset, with `operation_id` set); else `PROCESSOR_PAUSED` while [paused](#pause-and-resume); else `PROCESSOR_FAILING` for 60 s after a record exhausted its attempts, a letter could not be parked or the subscription reported an error; else `PROCESSOR_STARTING` before the first assignment and between a `Revoked` and the next `Assigned` (an empty assignment counts as assigned: such an instance is running); else `PROCESSOR_RUNNING` |
| `segments` | the assignment, sorted by `segment_order`; per segment `position` (the next position this instance delivers), `committed` (after its last acknowledgement), `head` and `lag` (`committed` to `head`, `position` to `head` without a commit; `-1` when unknown, never negative otherwise), and `replay_until` while an open replay range has not been passed |
| `processed_total`, `failed_total` | records whose delivery completed, a skipped duplicate included, and records that exhausted their attempts, since start (`SEQUENCED` and `INVALID` letters count in neither) |
| `dead_letters` | the store's dead-letter count at start, every 30 s and right after this instance parked a letter; `0` unless the mode is `collection` |
| `last_error`, `last_error_at_ms` | the last failure's error message, never the payload, cut at 512 bytes (a handler's exception class is prefixed, `TypeError: ...`; a subscription or park failure is plain text) |
| `event_types`, `dead_letter_mode` | the types with a handler in the processor, sorted; the [dead-letter mode](#dead-letters) |
| `operation_id` | the reset operation holding the processor's lock, empty when none |
| `replaying` | an open replay range on this instance's subscription has not been passed |
| `event_store`, `capabilities` | the event store's `name` and `capabilities`, distinct and sorted, each within the protocol's 64-byte name bound |

## Processor control

The hub is the control plane: its dashboard and HTTP API pause, resume and reset a processor on every instance, and
work its dead letters (see [the hub's processor control](/docs/server/processor-control/), which owns the routes and
the write credential). The hub keeps nothing. Each processor's pause, reset lock and replay ranges live in the service's
message store, in the processor-control port, which every instance reads once at start and then every 5 s; a
`ControlRequest` is only the fast path, and an instance that missed one converges on its next poll.

Every request is handled off the hub stream's read loop — the read loop only queues it, so heartbeats and request
dispatch keep flowing — one at a time per processor, in arrival order, and answered with **exactly one** `ControlReply`
carrying the request's `control_id`, on the stream the request arrived on (a reply for a stream that is gone is
dropped). An unknown action is `CONTROL_REFUSAL_INVALID`; a processor this instance does not run is
`CONTROL_REFUSAL_UNKNOWN_PROCESSOR`; an exception inside an action is `CONTROL_REFUSAL_FAILED`. Every action is logged at
INFO with its control id, processor, action and result. The actions are `pause`, `resume`, `reset_prepare`,
`reset_execute`, `reset_finish`, `dead_letter_list`, `dead_letter_retry`, `dead_letter_retry_all` and
`dead_letter_discard`; a refusal is one of `INVALID`, `LOCKED`, `NOT_PREPARED`, `SUBSCRIBERS_ACTIVE`,
`RESET_HANDLER_FAILED`, `UNKNOWN_PROCESSOR`, `NOT_FOUND`, `UNSUPPORTED` or `FAILED`, with a message cut at 512 bytes.

A renewal of the operation an execute holds and a `dead_letter_list` are answered beside the execute, never behind it
(the hub renews every 10 s and waits at most 10 s for an answer). A dead-letter change (`retry`, `retry_all`, `discard`)
during an execute is refused `LOCKED` at once, so it cannot race the reset handlers and the marker deletion.

### Pause and resume

A pause is written to the message store first, with the request's control id as its author (`local` for a local
write), and then applied here: the processor's subscription stops delivering **without leaving it** (the event store
keeps the assigned segments, and a record handed out before the pause comes again on the resume), and the status reads
`PROCESSOR_PAUSED`. A resume clears the stored pause and delivers from where it stopped. The state is idempotent, so a
repeated pause is not an error.

A processor that starts while the stored state says paused starts paused; it reads the state before it subscribes, so a
pause is never missed between a restart and the first poll. A message store without the processor-control port leaves
its processors running unpaused and is not asked again; it cannot persist a pause.

A pause stops subscription delivery only: dead-letter actions keep working (a retry runs the handler directly), and the
status tick, the control workers and the rest of the library are unaffected. A reset lock is separate from a pause: a
reset leaves the processor stopped, and the finish resumes consumption still paused if it was paused before.

## Reset and replay

A reset moves the subscription of a processor to a new position as a **leased operation**, in three control actions.
The state lives in the message store's `processor_control` state (the `snodra_processor_control` table in SQL, the
`processor_control` collection in MongoDB, one row or document per processor): its pause, its operation
`{id, kind: "reset", lease_until, prepared_at}`, and its open replay ranges. `ProcessorControlStore` is the port
(`get`, `set_paused`, `lock`, `extend`, `release`, `expire`, `set_replay`, `remove_range`), and
`ProcessorControlState`, `ControlOperation` and `Locked` are its values; every write is a write of its own, outside any
transaction.

1. **Prepare.** `reset_prepare` takes the processor's lock for the operation id until the requested lease (at least
   1 s) and leaves the subscription: the consumer finishes the record in hand and stops reading, and the status reads
   `PROCESSOR_STOPPED` with `operation_id`. Preparing the same operation again renews its lease; another operation
   holding an unexpired lease is `CONTROL_REFUSAL_LOCKED`, and an operation that already ended on this instance is
   `CONTROL_REFUSAL_NOT_PREPARED`. An instance that starts, or polls, while a foreign lock it was not prepared for is
   unexpired keeps out of the subscription too.
2. **Execute.** `reset_execute` must be answered by the instance that prepared the operation (`NOT_PREPARED`
   otherwise). The event store's admin plans the target per segment; a plan with members still reading is
   `CONTROL_REFUSAL_SUBSCRIBERS_ACTIVE` and nothing changes. Then, in this order: the processor's reset handlers (only
   when something replays), the deletion of its stage-1 markers in the ranges, the ranges written to the state, a
   second check that no instance reads the subscription, and the commit of the new positions. The execute renews its
   lease every 10 s (at most a third of it) and refuses with `FAILED` "lease lost: ..." after 120 s or when the lease
   cannot be renewed, before moving anything more. Its reply (`ResetDone`) carries the ranges, the markers deleted and
   the number of reset handlers that ran.
3. **Finish.** `reset_finish` releases the lock, remembers that the operation ended on this instance and consumes
   again, still paused if it was paused before. A finish for an operation nothing holds is OK (it never claims to have
   released a lock); another operation's lock is `NOT_PREPARED`. A late renewal after the finish never takes the lock
   again: an operation that ended here (finished, aborted, its lease passed or its lock lost) is remembered for at
   least `max(2 x lease, 60 s)`, at most a day, and a prepare or renewal of it is refused `NOT_PREPARED`.

A hub that dies mid-reset stops renewing: the lease passes, and every instance releases the operation on its next poll
(`expire`) and consumes again by itself; an execute in flight gives up at its limit and refuses. A refusal after the
reset handlers ran is **not "nothing changed"**: their effects stay, and the message says what else happened, for
example `reset handlers ran (2), 37 markers deleted, replay ranges written, positions not moved: retry the reset`.

**Targets.** `Earliest()` moves every segment to its first position (everything the event store still keeps is a
replay); `Latest()` moves it to its head (nothing is replayed); `Timestamp(timestamp_ms)` to the first position
appended at or after that time (else the head); `Positions((segment, position), ...)` moves the listed segments, each
once, and leaves a segment it does not list at its committed position. An unknown segment or a position past the head is
`INVALID`. These are the same values the hub's reset target carries; an add-on's `EventStoreAdmin.plan(target)` returns
one `ReplayRange` per segment it addresses.

**Ranges and replay.** A `ReplayRange(source, segment, start, until)` means the records of `segment` at positions
`start` (inclusive) to `until` (exclusive) are a replay; `start` is the target, `until` the subscription's committed
position before the reset (empty when it had none). Only a range with `until` set and `start` before it replays
anything; `latest` makes none. In a replay the processor's handlers run again except those registered with
`replay=False`, the stage-1 marker is still recorded (and the record acknowledged), and the sagas are never run.
The range closes once the committed position of a segment this instance holds (or its next
position while nothing is committed) reaches its `until`: the instance removes it from the state, and the status stops
showing `replaying`; another instance's range is left to that instance. A reset never touches the dead letters.

```python
# Once per reset that replays anything, on the instance that executes it, before any marker
# or position moves. An exception stops the reset with RESET_HANDLER_FAILED; the handlers
# that ran have run.
@app.reset_handler("orders")
async def clear_orders(reset: snodra.ResetContext) -> None:
    if isinstance(reset.target, snodra.Earliest):
        await orders.delete_all()   # the projection is rebuilt from the replay

# Never again in a replay: an effect outside the database.
@app.event_handler(processor="orders", replay=False)
async def on_order_placed(event: OrderPlaced) -> None:
    await mail.confirm(event)
```

`@app.reset_handler` takes the `default` processor; `@app.reset_handler("orders")` a named one, and the name matches
`[a-z0-9][a-z0-9-]{0,47}`. The function is an `async def` taking a `ResetContext` or nothing, and the handlers of a
processor run in registration order. Registration happens before `start` (`RegistrationClosed` after it), and a
function that is not such an `async def` raises `TypeError`. `ResetContext` is `(processor, operation_id, target,
ranges)`; `ranges` is never empty when the handlers run. `replay=False` is an argument of
`@app.event_handler`/`@app.event_handler(...)`, alongside `processor=`.

## Dead letters

A record a processor cannot handle is kept, not only logged. `Settings.dead_letter_mode`
(`SNODRA_EVENTS_DEAD_LETTER_MODE`) chooses where it goes:

| Mode | What happens | Sequenced per key | Hub control |
|---|---|---|---|
| `collection` (default) | parked in the message store's dead letters (`dead_letters` in MongoDB, `snodra_dead_letters` in SQL), then the record is acknowledged | yes | list, retry, retry-all and discard |
| `event-store` | published to the event store's dead-letter source `<source>.dlt` (`dead_letter_source(source)`), which needs `Capability.NATIVE_DEAD_LETTER`; the record is acknowledged once the store took it. **The topic or stream must exist** | no | none (the destination is the operator's) |
| `log` | logged (never the payload) and skipped | no | none |

The three reasons, per processor and stage 1 only:

- `DeadLetterReason.HANDLER_FAILED`: the processor's handlers failed on every attempt (`attempts` is the invocations
  made; one for a payload the type cannot be read from). It blocks its key.
- `DeadLetterReason.SEQUENCED`: the record's key has an earlier letter in this processor; it is parked without running
  the handlers, and `blocked_by` names the key's head letter. A record without a key is never sequenced. It blocks its
  key.
- `DeadLetterReason.INVALID`: no `type` header, or a value that is not a JSON object for a type the processor handles.
  It blocks nothing and can only be discarded. A type no handler of the processor knows is skipped, not a letter.

A letter's id is `letter_id(processor, source, segment, position)`, that is
`<processor>:<source>:<segment>:<position>` (`<processor>:<topic>:<partition>:<offset>` on Kafka), so a redelivered
record finds its own letter and is acknowledged instead of parked twice. A `DeadLetter` has `parked_at_ms`,
`last_attempt_at_ms` and `expire_at_ms` (`Settings.dead_letter_retention`, 30 days by default; the store's retention
removes it), and its `replay` flag says it was parked while its processor replayed the record, so its retry is a replay
too. The document keeps the record's `key`, `headers`, `event_id` (the `id` header), `event_type` (the `type` header)
and `payload` byte for byte.

In `event-store` mode the published event carries the record's key, value and headers (minus the six the library
writes) and six `snodra-dlt-*` headers: `snodra-dlt-processor`, `snodra-dlt-reason`,
`snodra-dlt-error` (`<type>: <message>`, at most 2000 characters), `snodra-dlt-original-topic`,
`snodra-dlt-original-partition` and `snodra-dlt-original-offset`.

**Working the letters through the hub.** These actions answer only in mode `collection`; in `event-store` and `log`
every one is refused `INVALID` ("there is nothing to list, retry or discard").

- `dead_letter_list` takes a limit of 1 to 100 and answers the oldest letters first, without payloads or headers, with
  the processor's total count.
- `dead_letter_retry` retries one letter: the processor's handlers for its type run in stage 1 under the record's
  marker, and the letter's deletion is in the same transaction, so a failure keeps the letter (`attempts + 1`, the new
  error and last attempt, reason `HANDLER_FAILED`) and a crash can neither handle it twice nor handle it and keep it.
  The outcome is `Retried`, `Duplicate` (a marker existed already: the letter is deleted), `Failed`, `Blocked` (the
  key's earlier letter must go first; the detail names it), `NotRetriable` (`INVALID` or no event type) or `NotFound`.
  No back-off; the sagas are not re-run.
- `dead_letter_retry_all` goes per key in position order, keys by their head letter's `parked_at_ms`, a key stopping at
  its first failure (its later letters count as `blocked`), then the keyless letters by `parked_at_ms`; `INVALID`
  letters are `skipped`. It answers the counts `retried`, `failed`, `blocked` and `skipped`.
- `dead_letter_discard` deletes a letter (`NOT_FOUND` when it is gone); discarding a key's head unblocks its next
  letter. A letter that expires unblocks its key too.

A retry reaches only the processors this instance runs; a letter of another processor is `NotFound` (retry) or
`NOT_FOUND` (discard). `DeadLetterStore` is the port an add-on implements (`park`, `head`, `earlier`, `parked_keys`,
`get`, `list`, `summaries`, `count`, `delete`, `delete_in`, `record_failure`); the in-memory message store implements it
and the control state, for tests.

## Sagas and deadlines

A saga is a long-running process that reacts to events, keeps its own state, sends commands and events, waits, and
ends. It is the saga model of the Kotlin and Rust libraries, for integrations with external systems: the saga records
what it wants done, a relay sends it after the transaction commits, and the external system's answer comes back as an
event or as the local `SagaCommandFailed` notice. A saga runs inside the service, against its message store and its
event-store consumer; the hub only carries the commands it sends to another service. Sagas run in the `default`
processor only.

```python
@snodra.message_type("payments.ChargeCard")
@dataclass
class ChargeCard:
    order_id: str


@app.saga("orders")
class OrderSaga:
    # State: annotated fields, persisted as JSON after every handled message. A dataclass also works.
    order_id: str = ""
    payment_ref: str = ""
    step: str = ""

    @snodra.saga_start("order_id")
    async def placed(self, event: OrderPlaced, ctx: snodra.SagaContext) -> None:
        self.order_id = event.order_id
        self.payment_ref = f"pay-{event.order_id}"
        ctx.associate_with("payment_ref", self.payment_ref)
        ctx.send(ChargeCard(order_id=event.order_id), routing_key=event.order_id)
        ctx.schedule(15 * 60, "charge-timeout")

    @snodra.saga_event("payment_ref", end=True)
    async def charged(self, event: ChargeSucceeded, ctx: snodra.SagaContext) -> None:
        self.step = "charged"

    @snodra.saga_deadline("charge-timeout", end=True)
    async def timed_out(self, ctx: snodra.SagaContext) -> None:
        self.step = "timed-out"
        ctx.publish(OrderPaymentFailed(order_id=self.order_id), key=self.order_id)

    @snodra.saga_command_failed(end=True)
    async def failed(self, event: snodra.SagaCommandFailed, ctx: snodra.SagaContext) -> None:
        self.step = event.reason
        ctx.publish(OrderPaymentFailed(order_id=self.order_id, reason=event.reason),
                    key=self.order_id)
```

The definition:

| Element | Meaning |
|---|---|
| `@app.saga(name=None)` | Registers the class. It needs a no-argument constructor, at least one `@saga_start` handler, and fields that round-trip through the codec as JSON. The name defaults to `module.Class`; give it one to keep stored sagas valid when the class moves. A duplicate name or a handler the library cannot serve raises `SagaError` naming the saga and handler. |
| `@saga_start(association, *, key=None, header=None, force_new=False, end=False)` | A handler that may create an instance. `association` is a field of the event (or `header=` names a message header); `key=` names the association differently. The event starts one when no live instance matches; at most one live instance exists per start key. `force_new=True` always starts one, without a start key. `end=True` ends the instance after the handler. |
| `@saga_event(association, *, key=None, header=None, end=False)` | A handler of an event on the live instances associated with the value. |
| `@saga_deadline(name, *, end=False)` | A handler of deadlines named `name`. A payload parameter receives the scheduled payload, or `None` when none was scheduled; a context-only handler receives the `SagaContext`. One handler per name. |
| `@saga_command_failed(*, end=False)` | The handler of the local `SagaCommandFailed`; it is routed to the sending instance by `saga_id`, no association needed. |

Handlers are `async def`; the event handler's first parameter is the event class and the `SagaContext` parameter is
optional. A deadline handler's first parameter is either the payload type, which receives `None` when no payload was
scheduled, or the `SagaContext`, in which case it always receives the context. Postponed
annotations (`from __future__ import annotations`) are resolved, so `ctx: snodra.SagaContext` works. Handlers of one
event type run in declaration order. The state is persisted as JSON: a field the codec cannot carry fails registration
and names the saga.

`SagaContext` is the only supported way to act from a handler:

| Member | Meaning |
|---|---|
| `saga_id`, `version`, `message_id`, `event_type`, `correlation_id`, `headers` | The instance and the delivered message. A deadline's message id is the deadline id, its type `deadline:<name>`, its headers empty and its correlation the scheduling message's. |
| `associations`, `ended`, `dispatch`, `deadline_ops` | What the handling has recorded so far (read-only views). |
| `associate_with(key, value)`, `remove_association_with(key, value)` | Add or remove an association. Removing the start association frees the start key. |
| `end()` | Ends the instance after the handler returns and cancels its scheduled deadlines. |
| `send(command, routing_key=None)`, `publish(event, key=None)` | **Record** a command or event in the saga's transaction, sent after the commit, in order. `publish` only encodes here: an event the outbox refuses is given up by the relay as `INVALID`, with no notice, and the later entries go on. |
| `schedule(after, name, payload=None, *, at=None)` | Record a deadline after a number of seconds, a `timedelta` or an instant, or `at=` an instant; returns its id. The payload is JSON with its type name. |
| `cancel_deadline(id)`, `cancel(id)`, `cancel_deadlines(name)`, `cancel_all(name)` | Cancel a deadline, or every scheduled deadline of that name. |

A handling records at most 999 messages. Nothing is sent or published while the handler runs. `app.send` and
`app.publish` raise `ConfigurationError` naming `SagaContext` inside a saga handler; do not keep a sender or bus to use
there either.

**Start keys and matching.** A start key is `"<type>|<key>=<value>"` with `%`, `|` and `=` escaped. It lives with its
association: removing that association, or ending the instance, releases it, so a later start event for the same value
creates a new instance. When no live instance matched any handler, a start handler whose association value is present
creates one; the new instance then runs every handler of that event whose association is that key and value.

### Stage 2

The saga stage runs in the `default` processor **after** stage 1 committed, and also when stage 1 exhausted its
attempts, before the record is acknowledged. A record inside an open replay range is skipped: a replay never runs a
saga again. A record parked `SEQUENCED` behind an earlier dead letter runs the saga stage before it is parked, in the
reference order (duplicate check, stage 2, park).

Per (event, saga type), one message-store transaction:

1. inserts the marker `saga:<type>:<eventId>` (a conflict retries the event, it is not a duplicate);
2. resolves every live instance of the type by each handler's association, and a `SagaCommandFailed` by its `saga_id`;
3. runs the matching handlers, in one transaction with the state writes, the dispatch entries and the deadline changes;
4. commits, then acknowledges the record.

The state uses optimistic version 0 at creation and `+1` per write; a version or start-key conflict retries the event
up to 5 attempts (200 ms doubling to 5 s, jittered), and a handler failure gets 2 quick attempts (50 ms apart). An event
that fails every attempt is parked in `saga_failures` with its marker, in a separate transaction, and the consumer moves
on. The marker is committed even when no instance matched.

### The dispatch relay

Every instance runs the relay. It polls every 200 ms: it reads the sagas with a pending entry, starts a task per saga
(at most 100 per pass), and claims a saga's dispatch lease for 60 seconds. One saga's entries go strictly in `seq`
order under the lease; a slow send holds only its own saga, not the polling pass.

- **An event entry** is appended to the ordinary outbox and marked sent in one transaction, with a fresh event id, the
  entry's key, the recording message's correlation id and a valid trace. An event the outbox refuses is given up at
  once as `INVALID`, with no notice, and the later entries go on.
- **A command entry** is sent by its wire type with its stored JSON, routing key, `idempotency-key`
  (`<sagaId>:<seq>`), `saga-id`, the recording message's correlation id and traceparent, and **no authorization** or
  caller identity. The sender uses `retry=False`: the relay owns every retry. A local handler is preferred unless
  `always_route_through_hub` is on; a command with no local handler and no configured hub is `NO_HANDLER` at once.
- **At least once.** An entry is marked sent after its reply. A crash in between sends it again with the same
  idempotency key, so every handler of a command a saga sends must be idempotent by `idempotency-key`.
- **The send bound.** A send is waited for at most 60 seconds; a send that ignores cancellation is abandoned, its task
  cancelled, and the entry retried with the same key.

A failed attempt is classified as **transient** or **permanent**:

| Transient (retried) | Permanent (notice at once) |
|---|---|
| never sent; unknown outcome; hub `NO_HANDLER`; `TIMEOUT`; `HANDLER_DISCONNECTED`; `RESOURCE_EXHAUSTED`; `{"snodra":"retryable"}`; a non-messaging sender failure | local `NO_HANDLER`; `UNAUTHENTICATED`/`PERMISSION_DENIED` (`DENIED`); `INVALID_REQUEST` (`INVALID`); `{"snodra":"unknown-outcome"}` (`UNKNOWN_OUTCOME`); any other `HANDLER_ERROR` or `CANCELLED` (`FAILED`) |

A transient failure waits 1 s, doubling to 5 minutes (±20 %), 10 attempts in all, then becomes `EXHAUSTED`. The failure
and its pending notice are written before the notice is delivered, and the saga's later entries are still sent.
A permanent failure is recorded at once.

### `SagaCommandFailed`

`snodra.SagaCommandFailed` has `saga_id`, `command_type`, `idempotency_key`, `reason` and `message`; its
`notice_id` is `failed:<sagaId>:<seq>` and it carries the command's correlation id. The runtime routes it to the live
instance of its type that handles it, by `saga_id`, without an association, and also runs the ordinary
`@app.event_handler` handlers of every processor that has one, each under its own marker
`processor:<processor>:failed:<sagaId>:<seq>` (empty source, segment and position). It is **never** published to the
event store.

| Reason | When |
|---|---|
| `NO_HANDLER` | Nobody handles the command type in a service with no hub. A hub's `NO_HANDLER` is transient and ends as `EXHAUSTED`. |
| `DENIED` | The handler requires an authenticated caller (or denies the caller): a saga command has no caller. |
| `INVALID` | The handler could not read the payload. |
| `FAILED` | The handler failed with any other error, including an idempotent adapter's permanent failure. |
| `UNKNOWN_OUTCOME` | An idempotent adapter cannot tell whether its external call happened. |
| `EXHAUSTED` | A transient failure lasted through all 10 attempts. |

A notice that cannot be delivered is retried on the command backoff and given up after 10 attempts, logged at error; a
notice nobody handles is logged at error. A permanently failed command does not hold back the saga's later entries.

### Deadlines

`schedule` and the cancel operations are recorded in the saga's transaction. Every instance runs a scheduler every
second: it claims each due deadline with a 30-second lease, then runs the handler, writes the state, its dispatch
entries and the deadline changes, and marks the deadline fired, all in one transaction. A deadline no longer scheduled
is left alone; one whose saga ended, is gone or has no handler of that name is cancelled. A failed firing retries like
an event and leaves the claim to expire, so the deadline fires again after the lease: **at least once**, never before
its due time, never for a cancelled deadline or an ended saga. Ending the instance cancels its scheduled deadlines.
A deadline handler sees empty `headers`, the scheduling message's `correlation_id` and no trace; the commands it
records carry that correlation and no traceparent.

Leases are timestamps written by one instance and compared with another instance's clock: keep the instances' clocks
in step (NTP or the platform's time sync).

## Idempotent external calls

`@app.idempotent_command_handler` makes a command handler safe to call again with the same key: each call is recorded
in the message store's `external_calls` before the body runs.

```python
@app.idempotent_command_handler(external_idempotent=True)
async def charge_card(cmd: ChargeCard) -> ChargeReceipt:
    key = snodra.current_message().headers["idempotency-key"]
    try:
        return await gateway.charge(cmd.order_id, key)
    except GatewayUnavailable as error:
        raise snodra.Retryable(str(error)) from error      # nothing was charged: try again later
    except GatewayAmbiguous as error:
        raise snodra.UnknownOutcome(str(error)) from error  # it may have charged
```

- **The key** is the `idempotency-key` header. A saga's relay sets it to `<sagaId>:<seq>`. A missing or blank key is a
  plain `HandlerError` naming the command and the header, before any record or body. The key is the header only: the
  library does not evaluate a typed key expression (the Kotlin library's `@IdempotentHandler(key = ...)`).
- **The record lifecycle.** The first call inserts `IN_PROGRESS` with a fresh owner and a 5-minute lease;
  the first insert wins. A concurrent call sees the owner's in-flight record and
  raises `Retryable`. A repeat after `SUCCEEDED` returns the stored reply bytes without running the body. A repeat
  after `FAILED` raises a plain `HandlerError` with the stored message. `UNKNOWN` raises `UnknownOutcome` again.
- **A lapsed call.** An `IN_PROGRESS` record past its lease is expired to `UNKNOWN` by default, or taken over and run
  again with `external_idempotent=True` (the partner de-duplicates by the key). A record that changes between the read
  and the write is read again (three rounds at most), and the caller is asked to come back; a slow call's success is
  returned rather than overwritten.
- **Settlements are owner-conditional.** A body failure with `Retryable` resets the record (the next call runs the body
  again; the relay owns the backoff), `UnknownOutcome` marks it unknown, and any other exception stores `FAILED` with
  the `HANDLER_ERROR` JSON and is raised unchanged. A settlement matches the owner token, so a call whose lease ran
  out never overwrites the record of the call that took it over.
- **A panic** — a `BaseException` that is not an `Exception`, `asyncio.CancelledError` excepted — is settled `UNKNOWN`
  and answered with the unknown-outcome marker, matching the Go choice. Kotlin settles `FAILED`; here the external call
  may have happened, so the safe answer is unknown. `CancelledError` leaves the record `IN_PROGRESS` for its lease.
- **An unrecorded success** (the body returned but its reply could not be encoded or stored) is never reported as
  success: with a de-duplicating partner it is `Retryable` and the record stays `IN_PROGRESS`; otherwise it is
  `UnknownOutcome` and the record is marked `UNKNOWN`.
- **Store failures before the body** are a plain permanent `HandlerError`, as in Kotlin; the body never runs and a
  saga records `FAILED`.
- **The records are their own short writes**, outside the caller's transaction: a rolled-back caller never forgets a
  call that happened. The adapter never retries a call itself; the saga relay owns the retry.
- **The markers.** `snodra.Retryable` and `snodra.UnknownOutcome` write `Error.details` exactly
  `{"snodra":"retryable"}` or `{"snodra":"unknown-outcome"}`. `snodra.is_retryable` and `snodra.is_unknown_outcome`
  read the marker from the exceptions, a `HandlerError` or `HubError` details value, an explicit `__cause__` chain and
  a `BaseExceptionGroup`, trimming surrounding whitespace.
- **Startup.** The handler needs a message store and its external-calls port: `start` probes it after schema
  preparation and raises `ConfigurationError` naming the handler and the port when it is missing or `Unsupported`. An
  idempotent-command-only service needs no event store.
- **Commands only.** There is no idempotent event-handler adapter; wrap an external call in an idempotent command.

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
key, at-least-once delivery with acknowledgement, pause and resume, the headers as the store's native metadata, and the
admin side of a reset (`admin`, `members`, `plan`, `apply`). The message-store interface is frozen through level 4: its
outbox, processed-event, dead-letter, processor-control, external-call and saga ports are implemented by both official
stores (the dead-letter and control ports since 0.7.0, the external-call and saga ports since 0.8.0), which pass the
eleven level-4 store checks. A third-party add-on implements the same interfaces and depends on the core only;
`snodra.testing` is its conformance kit (see [Testing](/docs/messaging/python/testing/)).

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

## Limits and differences

The library is at feature level 4, with these documented limits:

- **No event browser.** Its event-store add-ons declare no `browse` capability, and its event-store kit omits the four
  positive `browse` checks while running `no_browser_without_capability`.
- **The adapter key is the header only.** There is no typed key expression like Kotlin's
  `@IdempotentHandler(key = ...)`; a key derived from the message must be set as `idempotency-key` by the caller.
- **An adapter panic is an unknown outcome.** A `BaseException` that is not an `Exception` (other than
  `CancelledError`) is settled `UNKNOWN` and answered with the unknown-outcome marker, not Kotlin's `FAILED`; the call
  may have happened.
- **Commands only.** `@app.idempotent_command_handler` is the idempotent adapter; there is no idempotent event-handler
  adapter.
- **No saga or external-call metrics.** The telemetry interface has no counters for them; the outcomes are in the
  store and the logs. The rest of the metric names and labels match the Kotlin, Rust and Go libraries.
- **No dedicated admin helper for parked saga events.** They are in the message store's `saga_failures` records,
  reachable through the store's saga ports; the library has no `SagaFailures` list/retry/discard class like Kotlin's or
  Rust's.
- **The level-4 clocks are fixed.** The saga stage, relay, deadline scheduler and external-call lease use the
  library's fixed timings, with no `SNODRA_*` variable or `Settings` field yet
  ([Configuration](/docs/messaging/python/configuration/#sagas-deadlines-and-external-calls)).
- **Leases need synchronised clocks.** The dispatch lease, the deadline claim and the external-call lease compare one
  instance's timestamp with another's; keep the clocks in step.

For a language-specific API, see the [Kotlin](/docs/messaging/kotlin/) and [Rust](/docs/messaging/rust/) pages.

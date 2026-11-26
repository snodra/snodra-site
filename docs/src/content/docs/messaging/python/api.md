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

## Not in the Python library yet

Events, event stores, message stores, the outbox, event processors, dead letters and sagas (feature levels 2 to 4) are
not in the Python library. Use the [Kotlin](/docs/messaging/kotlin/) or [Rust](/docs/messaging/rust/) library for them.

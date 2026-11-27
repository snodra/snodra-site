---
title: "API"
---

The package is `snodra`, imported as `snodra "github.com/snodra/snodra-messaging-go"`. `go doc -all` on it is the
complete reference; this page is the tour. Every snippet below is compiled by the library's tests.

## Messages

A message is a Go type with a `MessageType() string` method (a value or a pointer receiver), which returns the type name
every handler registers for and every sender addresses, for example `orders.PlaceOrder`. The payload is JSON
(`encoding/json`, unknown fields ignored on read), the same JSON every Snodra library reads and writes; `snodra.Codec`
changes the codec, and only a codec that writes the same JSON keeps the services of other languages working. A result
type `R` is any type; `snodra.Empty` answers `{}`, and so does a nil pointer.

## Handlers

`HandleCommand`, `HandleQuery`, `HandleStream` and `HandleSubscription` register a handler for a type, taking the
`*snodra.App`, a function and handler options. Handlers are registered before `App.Start` (or `Run`). A registration
error is returned at once and kept: `Start` returns every one of them, joined, and does not start. The errors are: a
registration after `Start` (`ErrRegistrationClosed`), a type registered twice (as a command and a query, say), an empty
type name, a nil handler, a `RequireCaller` without a function, a command with `Shared`, and a guard
(`RequireAuthenticated`, `RequireRole`, `RequireCaller`) without `snodra.JWKS`.

- A handler runs with a context that is cancelled when the hub cancels the request (the caller gave up, or the request
  timed out). A handler that ignores its context keeps its permit and its concurrency slot until it returns.
- A panic in a handler is recovered and answered as `HANDLER_ERROR` with the message `handler panicked`.
- `MaxConcurrent` handlers run at once; the rest wait at the hub.

### Handler errors

A handler's error is answered `HANDLER_ERROR` unless it was made with `snodra.Unauthenticated`,
`snodra.PermissionDenied` or `snodra.InvalidRequest`, which answer `UNAUTHENTICATED`, `PERMISSION_DENIED` and
`INVALID_REQUEST`. `snodra.WithDetails(err, details)` attaches machine-readable details (JSON), which only a
`HANDLER_ERROR` carries.

### Guards

```go
// An anonymous caller is refused before the payload is decoded; a guard needs snodra.JWKS.
_ = snodra.HandleCommand(app, func(ctx context.Context, cmd ArchiveOrder) (snodra.Empty, error) {
	caller, _ := snodra.CallerFrom(ctx)
	fmt.Println("archived by", caller.Subject)
	return snodra.Empty{}, nil
}, snodra.RequireRole("orders-admin"))
```

`RequireAuthenticated`, `RequireRole` and `RequireCaller` answer an anonymous caller `UNAUTHENTICATED`, before the
payload is decoded, and a caller they refuse `PERMISSION_DENIED`, once the payload is decoded. When a handler has
several, every one must accept. Every guard needs `snodra.JWKS` (or `SNODRA_JWKS_URL` and `SNODRA_ISSUER`): registering a
guarded handler without it is an error, and `Start` and `Run` fail. `snodra.Shared()` registers a query
type (also a streaming or subscription query) as shared: many services may own it, and a `Gather` asks every instance
of every owner. Every owner must register it shared.

## Sending

Any service, including one that owns no handler, sends with `Send` (a command, to the one instance that handles its
type) and `Query` (a query):

```go
receipt, err := snodra.Send[Receipt](ctx, app, PlaceOrder{OrderID: "o-1", Cents: 1250},
	snodra.RoutingKey("o-1"), snodra.Timeout(3*time.Second))
if err != nil {
	var e *snodra.Error
	switch {
	case errors.As(err, &e):
		fmt.Println("the hub or the handler answered", e.Code, e.Message)
	case errors.Is(err, snodra.ErrNeverSent):
		fmt.Println("no handler saw it: sending it again is safe")
	case errors.Is(err, snodra.ErrOutcomeUnknown):
		fmt.Println("it may or may not have run")
	}
	return
}
order, err := snodra.Query[Receipt](ctx, app, GetOrder{OrderID: receipt.OrderID})
```

The options of a call (`SendOption`):

| Option | Meaning |
|---|---|
| `Timeout(d)` | this call's timeout, sent as `Request.timeout_ms`; wins over `DefaultTimeout`; a context deadline that comes sooner is the timeout instead; with none, the hub applies the type's own timeout or its default |
| `RoutingKey(key)` | commands of one type with the same key go to the same instance of the owning service, typically the aggregate id; queries, streams and gathers ignore it |
| `Priority(p)` | the request's priority, higher first while the target's queue at the hub is not empty; wins over `Priorities` |
| `Header(name, value)` | adds a header, which the handler sees in `MessageInfo.Headers`; the names the library sets itself (`authorization`, `traceparent`, `tracestate`, `correlationId`, `correlation-id`, in any letter case) fail with `ErrReservedHeader` |
| `Retry(policy)`, `NoRetry()` | this call's retry policy; wins over `DefaultRetry` |
| `InitialCredit(n)` | the credit window of a `Stream` or `Subscribe` (default 64) |
| `MaxResults(n)` | ends a `Gather` after `n` successful parts, a `Stream` after `n` items, a `Subscribe` after `n` updates |

A request sent while a handler runs (with the handler's context, or one derived from it) carries that request's
correlation id, its caller's token (see `ForwardJWT`) and its trace context. Outside a handler it carries a new
correlation id.

While no hub can take a request (none connected yet, a hub restarting), the call waits for one within its timeout (5 s
without one), and only then fails with `ErrNeverSent`. One deadline bounds the call: a request moved to another hub
sends its full timeout again, and no new hub is tried once that timeout has passed.

### Requests answered in-process

A command, or a query that is not shared, of a type this instance handles itself is answered in-process: its handler
runs on the caller's goroutine with no hub, no permit and no handler slot, also before `Start` and after `Shutdown`.
It sees a fresh request id, the caller's `Header`s and the correlation id, and acts for the caller the hub path would
carry (the handled request's caller when `ForwardJWT` is on; anonymous outside a handler or with it off). The routing
key, timeout, priority and retry do not apply (the caller's context bounds the call), nothing goes to the telemetry,
and its errors are those a hub would have relayed. `snodra.AlwaysRouteThroughHub(true)`
(`SNODRA_SERVER_ALWAYS_ROUTE_THROUGH_HUB=true`) sends every request through a hub, so a routing key keeps its instance
affinity across the instances of the service. `Gather`, `Stream` and `Subscribe` always go through a hub.

### Retries

Retries are opt-in: `snodra.DefaultRetry(snodra.RetryNeverRan)` for every call, or `snodra.Retry(...)` per call.
`RetryNeverRan` is 3 attempts, 100 ms doubling up to 2 s, each wait jittered by +/-20 %. A command is retried only
when its handler never ran (`ErrNeverSent`, `NO_HANDLER`, `RESOURCE_EXHAUSTED`); a query is also retried after an
unknown outcome (`ErrOutcomeUnknown`, `TIMEOUT`, `HANDLER_DISCONNECTED`). Every attempt has a fresh request id and all
attempts share one time budget; never use `MessageInfo.ID` to detect a retried command.

## The four query modes

| Mode | Asking | Serving | Answer |
|---|---|---|---|
| point | `Query` | `HandleQuery` | one result from one instance |
| scatter-gather | `Gather` | `HandleQuery` with `Shared()` | the answers of every instance of every owner |
| streaming | `Stream` | `HandleStream` | many items, under the caller's credit |
| subscription | `Subscribe` | `HandleSubscription` | an initial result, then updates until it is closed |

```go
// Serving a stream: the items go out under the caller's credit.
_ = snodra.HandleStream(app, func(ctx context.Context, _ ListOrders, w *snodra.StreamWriter[Receipt]) error {
	for _, r := range []Receipt{{OrderID: "o-1", Total: 1250}, {OrderID: "o-2", Total: 80}} {
		if err := w.Send(ctx, r); err != nil {
			return err // the caller stopped reading, or the hub stream is gone
		}
	}
	return nil
})

// Reading one: breaking out of the loop cancels the stream at the hub.
for r, err := range snodra.Stream[Receipt](ctx, app, ListOrders{}) {
	if err != nil {
		return // the last thing the sequence yields
	}
	fmt.Println(r.OrderID, r.Total)
}

// Asking every instance of every owner of a shared query type.
gathered, err := snodra.Gather[Receipt](ctx, app, GetOrder{OrderID: "o-1"}, snodra.Timeout(2*time.Second))
if err == nil {
	fmt.Println(len(gathered.Parts), "answers from", gathered.Targets, "targets")
}
```

- **Gather.** Partial answers are answers: a gather where some targets failed or timed out still succeeds, and
  `Gathered` says what was missing (`Parts`, each with its `Service`, `Instance`, `Value` or `Err`; `Failed`;
  `TimedOut`; `Targets`). `Timeout` is the deadline of the whole gather.
- **Stream.** Nothing is sent until the range starts, and each range sends the query anew. An error is the last thing the
  sequence yields. Breaking out of the loop, an item that does not decode, lost parts and the local guard cancel the
  stream at the hub, which tells the handler, so credit and goroutines are released. A stream is retried only until its
  first item; after that nothing is retried, and a lost hub stream ends the sequence with `ErrOutcomeUnknown`.
  `StreamWriter.Send` waits for credit at most `StreamCreditTimeout` (10 minutes), after which the stream ends with
  `TIMEOUT` and the handler's context is cancelled; its permit and slot return only when the handler returns.
- **Subscribe.** Updates are hot: the hub relays them from the open on, up to the credit window.

```go
// Serving a subscription: the initial result now, updates whenever you emit them. The type
// arguments are the query, its initial result and its updates, as Subscribe[I, U] reads them.
updates, _ := snodra.HandleSubscription[WatchOrder, OrderStatus, OrderStatus](app, func(_ context.Context, q WatchOrder) (OrderStatus, error) {
	return OrderStatus{Status: "placed"}, nil
})
updates.Emit(func(q WatchOrder) bool { return q.OrderID == "o-1" }, OrderStatus{Status: "shipped"})

// Following one.
sub, err := snodra.Subscribe[OrderStatus, OrderStatus](ctx, app, WatchOrder{OrderID: "o-1"})
if err != nil {
	return
}
defer sub.Close()
fmt.Println(sub.Initial.Status)
for u, err := range sub.Updates() {
	if err != nil {
		return
	}
	fmt.Println(u.Status)
}
```

`HandleSubscription[Q, I, U]` returns `*Updates[Q, U]`, typed by the query and its update:
`Emit(match func(Q) bool, update U) int` reaches every open subscription whose match function accepts and returns how
many it reached; `Complete` and `Fail` end them. The type is declared to the hubs as a subscription type
(`Register.subscription_query_types`) on every registration, so a hub serves it with `Subscribe` only: a `Query`,
`Stream` or `Gather` of it, and a `Subscribe` of a query type that is not declared a subscription type, fail
with `INVALID_REQUEST` (a type nobody registered is `NO_HANDLER`). A subscription takes no permit and no handler slot, and `MaxSubscriptions` bounds
them. The caller's context bounds the whole subscription: when it ends, the subscription is cancelled at the hub.
`Updates()` can be ranged over once.

## Errors

A failed `Send`, `Query`, `Gather`, `Stream` or `Subscribe` is one of:

| Error | Test with | Meaning |
|---|---|---|
| `*snodra.Error` | `errors.As` | the hub's or the handler's answer, by `Code` (`CodeNoHandler`, `CodeTimeout`, `CodeHandlerDisconnected`, `CodeHandlerError`, `CodeUnauthenticated`, `CodeInvalidRequest`, `CodePermissionDenied`, `CodeResourceExhausted`, `CodeCancelled`), with `Message` and, for `CodeHandlerError`, `Details` |
| `ErrNeverSent` | `errors.Is` | the request was written to no hub within the call's timeout (5 s without one): sending it again is safe |
| `ErrOutcomeUnknown` | `errors.Is` | the request was written and no answer arrived: the handler may or may not have run |
| `ErrLostParts` | `errors.Is` | a stream or gather lost parts that were already announced |
| `ErrReservedHeader` | `errors.Is` | a `Header` name the library sets itself; nothing was sent |
| the context's error | `errors.Is` | the context ended first; once the request was written it comes with `ErrOutcomeUnknown`, else with `ErrNeverSent` |

A context deadline is the caller's timeout; a cancelled context returns at once with `context.Canceled`, together with
`ErrOutcomeUnknown` once the request was written (or, for a request answered in-process, once its handler failed after
the cancel). The library's
own `TIMEOUT` is returned when no answer came within the hub's bound for the request plus 1 s.

## Identity

`snodra.CallerFrom(ctx)` returns who sent the request being handled, read from its forwarded token once it is
verified against `snodra.JWKS`: `Subject` and `Roles`. It returns false for an anonymous caller and outside a handler.
Without a JWKS no token is an identity: every caller is anonymous, and the token only goes on with the requests the
handler sends. A header that is not a bearer token (the `Bearer` scheme is read in any letter case), or a token that is
not a signed JWS, is answered `UNAUTHENTICATED` with or without a JWKS, before the handler is looked up.
`snodra.MessageFrom(ctx)` returns the request's id, type, correlation id and headers. `RolesClaim`
says where roles are read in the token, and `ForwardJWT` whether outgoing requests carry the handled request's token.

## Lifecycle

`snodra.New` builds an `App` from options and connects to nothing; it fails on missing or invalid settings. Then:

- `App.Start(ctx)` opens a connection to every hub and returns at once; each registers and reconnects on its own. No
  handler can be registered after it.
- `App.Ready(ctx)` waits until a hub has acknowledged the registration.
- `App.Run(ctx)` starts, waits for `ctx` to end, then shuts down within 15 s.
- `App.Shutdown(ctx)` leaves the hubs in order: an empty registration so requests route elsewhere at once, then every
  subscription served here ends, then the handlers in flight (at most 5 s), then the stream half-close. It returns by
  `ctx`'s deadline. A handler that ignores its context outlives `Shutdown`: the library cannot stop a goroutine, so it
  stops waiting for it.
- `App.HubIDs`, `App.Rejection` and `App.SubscriptionsServed` report the state of the connections.

### Several hubs

An instance opens one stream to every hub it is given, each with the identical registration, and knows a hub by its
`RegisterAck.hub_id`. A second address that answers a hub id already served is parked and takes over if the first goes
away. With one `dns:///name:port` target, every address is a hub, resolved again every 30 s: an address that leaves the
answer is drained and closed, a new one is connected.

A unary request a hub answers `NO_HANDLER` goes to the other live hubs in turn, with the same id and its full timeout;
a hub that declined or did not take the request is not tried again in the same call. When every live hub declined, the
last `NO_HANDLER` is the answer at once; when the call's deadline passes with a live hub still untried, it fails with
`ErrNeverSent`. Without a routing key, the next hub is the first untried one in a new round-robin turn over all live
hubs (the order is not part of the protocol). Every later registration is followed by a heartbeat, which counts toward
the silent-hub rule.

## Telemetry

The core only defines an interface (`snodra.Instrumentation`, installed with `snodra.Telemetry`) and costs nothing
without one. The separate module `github.com/snodra/snodra-messaging-go/observability` (package `observability`) implements it on
the OpenTelemetry API
(the application installs the SDK and its exporters):

```go
app, err := snodra.New(
	snodra.Service("orders-service"),
	snodra.Hubs("snodra-server:7000"),
	snodra.Telemetry(observability.New()), // uses the global OpenTelemetry providers
)
```

```sh
go get github.com/snodra/snodra-messaging-go/observability@latest
```

`observability.New` takes `WithMeterProvider`, `WithTracerProvider` and `WithPropagator` to use others than the global ones. One
instrumentation serves one `App`. The metrics have the names and labels of the Kotlin and Rust libraries, so one
dashboard serves every library.

| Instrument | Kind | Labels |
|---|---|---|
| `snodra.hub.client.request.duration` | histogram, s | `kind`, `type`, `outcome` |
| `snodra.hub.client.handlers.in.flight` | gauge | |
| `snodra.hub.client.connected.hubs` | gauge | |
| `snodra.hub.client.token.fetches` | counter | `result` |
| `snodra.hub.client.certificate.rotations` | counter | |
| `snodra.hub.client.credentials.refreshes.sent` | counter | |

The request duration covers a `Send` or `Query` from the call to its result, retries included; a call its caller
cancels, a call its options refuse and a call answered in-process record no metric. The instrumentation scope is the
module's import path, `github.com/snodra/snodra-messaging-go/observability`. A request a handler serves gets a server span named after the message type, a child of the
request's `traceparent`, and the requests the handler sends carry its trace context. That span is the Go library's
own: the Kotlin and Rust libraries create none for the requests they serve.

## Events

An event is a message type like a command or a query: a Go type with `MessageType() string`, whose payload is a JSON
object. `Publish` builds it and appends it to the service's outbox, for example
`snodra.Publish(ctx, app, OrderPlaced{OrderID: cmd.OrderID, Total: cmd.Cents}, snodra.Key(cmd.OrderID))`.

`Publish` needs the message store and the event store ([Add-ons](#event-stores-and-message-stores)); without them the
first call fails, naming the missing one. It returns once the entry is appended, not when the event reaches the event
store. The event's type is `E`'s `MessageType`, its id a fresh UUID, its timestamp the creation time, and `Key` is its
order key (an empty key is a key; without `Key` the event has none). A payload that is not a JSON object, or whose
integers do not fit in a signed 64-bit integer, fails with `ErrInvalid` and nothing is appended.

### Event headers

Every published event carries the first six headers; `traceparent` is added when the work that published it carries a
trace context. `Publish` stores the correlation id, the user id and the trace context in the outbox; the relay adds
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

`snodra.EventHeaders` lists the seven names in order, and `snodra.HeaderID`, `HeaderType`, `HeaderCorrelationID`,
`HeaderTimestamp`, `HeaderSource`, `HeaderUserID` and `HeaderTraceparent` are the constants. The names are
header keys of `snodra.OutgoingEvent` and `snodra.Delivery`; the event key is not a header, it is the event store's
key. Outside any handling an event has no traceparent and its correlation id is a fresh UUID.

### The outbox and the relay

`Publish` appends in the transaction carried by its context: the one `store.Begin` started, the service's own
transaction bound with the SQL add-on's `WithTx` or the MongoDB add-on's `WithSession`, or a short transaction of its
own when the context carries none. A rolled-back transaction leaves no event. A committed one leaves an entry the
relay will publish.

Every instance runs one relay unless `OutboxEnabled(false)` (`SNODRA_OUTBOX_ENABLED=false`):

- **Claimed under a lease.** A relay claims pending entries in `(CreatedAt, Seq)` order, up to the batch size, and
  holds them for the lease (`SNODRA_OUTBOX_LEASE_MS`, 2 minutes by default). A crashed relay's entries are claimed
  again once its lease has passed; nothing is lost.
- **Sent one after the other.** The relay publishes an entry, then marks it sent. A crash between the two publishes
  the event again after the lease, and consumers skip the duplicate by its marker.
- **Order per key, per relay.** Events with one key reach the event store in publish order while one relay sends
  them. Several relays can claim different batches, so batches of different instances are not ordered against each
  other; run the relay on one instance (`OutboxEnabled(false)` on the others) when the order of everything one
  instance publishes must hold.
- **Failures.** An event the store rejects for good (`ErrRejected`) is given up at once; another failure counts an
  attempt and ends the batch, so the next claim retries that entry before the later ones. After
  `SNODRA_OUTBOX_MAX_ATTEMPTS` sends the entry is marked failed and logged.

### Event handlers

`HandleEvent[E Message](app, func(ctx context.Context, e E) error, opts ...EventOption)` registers a handler of the
event type `E`; `InProcessor(name)` puts it in a named processor. As for the other handlers, registration happens
before `Start` (or `Run`) and an error is returned at once and again by `Start`.

A handler runs inside the processor's transaction, together with the event's processed-event marker:

1. the store records the marker (`processor:<processor>:<eventId>`) in a transaction;
2. a marker that exists already means the event is a duplicate: no handler runs and the record is acknowledged;
3. every handler of the type, in registration order, runs in the same transaction (an error in one fails the record);
4. the transaction commits, and only then the record is acknowledged.

So the handler's own writes and the marker commit together, and a record that comes again after a crash is skipped
instead of handled twice. An event type the processor has no handler for is acknowledged and runs nothing; a record
without a type header, or whose payload is not a JSON object or does not decode as the handler's type, is logged and
acknowledged. A handler that fails is tried up to `SNODRA_CONSUMER_MAX_ATTEMPTS` times (5 by default), the first
included, one second apart; after that with the level-3 release the record becomes a dead letter in the `collection`
mode, the default ([Configuration](/docs/messaging/go/configuration/#dead-letters-level-3-in-progress)); the latest
level-2 release logs and skips it. A subscription that fails is reopened after 1 s, doubling up to 30 s, and the wait
starts over after a delivery or a subscription that lived 30 s.

An event handler has no caller: `CallerFrom` reports false (an event carries a user id, never a token).
`MessageFrom` returns the event's id, type, correlation id and headers. What the handler publishes carries that
correlation id, that user id and its trace context.

### Processors

| Processor | Registered with | Subscription | Markers |
|---|---|---|---|
| `default` | `HandleEvent` without `InProcessor` | `<service>.default` | `processor:default:<eventId>` |
| `<name>` | `HandleEvent` with `InProcessor(name)` | `<service>.<name>` | `processor:<name>:<eventId>` |

A processor name matches `[a-z0-9][a-z0-9-]{0,47}` (at most 48 characters) and is never `default`. One event type in
two processors reaches both, each in its own transaction and marker family: a failure in one does not affect the
other. `ProcessorSubscription(service, name)` and `ProcessorMarker(processor, eventID)` return the strings above.
Every instance of a service that registers a handler for a processor reads that subscription; the instances share its
segments, so a segment is read by one instance at a time.

**A new processor reads from the beginning of what the event store keeps.** Moving a handler from `default` to a
named processor, or adding a handler of an event type that has history, runs it over every event still in the store's
retention: the new subscription and its marker family are new. That is what a projection wants when it can rebuild;
a handler with effects outside the database repeats every one of them. Leave such a handler in `default`, or move the
new subscription to the end of the source before you deploy it with the event store's own tooling (for Kafka, reset
the consumer group `<service>.<name>` to `latest` while it has no member).

`ConsumerEnabled(false)` (`SNODRA_CONSUMER_ENABLED=false`) stops the instances reading event subscriptions, for a tool
that only publishes.

## Event stores and message stores

The two stores are add-ons: the core ships neither and imports neither. A service passes one of each to `New`, with
`snodra.WithStore(store)` and `snodra.WithEventStore(eventStore)`, next to `snodra.Service` and `snodra.FromEnv`.

| Add-on | Module | Interface |
|---|---|---|
| Kafka | `github.com/snodra/snodra-messaging-go/kafka` | event store |
| RabbitMQ Streams | `github.com/snodra/snodra-messaging-go/rabbitmq` | event store |
| MongoDB | `github.com/snodra/snodra-messaging-go/mongo` | message store |
| SQL (PostgreSQL, MySQL) | `github.com/snodra/snodra-messaging-go/sql` | message store |

The event-store interface expects one subscription per processor, competing instances sharing its segments, order per
key, at-least-once delivery with acknowledgement, pause and resume, and the headers as the store's native metadata. The
message-store interface is frozen at level 2: its outbox and processed-event ports are implemented by both official
stores, and so are, on `main`, the dead-letter and processor-control ports (claimed with the level-3 release); the
external-call and saga ports return `ErrUnsupported` until level 4. A third-party add-on implements the same interfaces
and depends on the core only; `snodratest` is its conformance kit (see [Testing](/docs/messaging/go/testing/)).

`App.Start` hands the message store the application's clock, then prepares its schema (`InitSchema`) or, with
`SNODRA_STORE_INIT_SCHEMA=false`, checks it (`CheckSchema`); a failure fails `Start`. A store that also implements
`StoreLifecycle` starts its own background work there (the SQL add-on's purge, for example). A publish or an event
handler without the two stores fails: an event handler at `Start`, naming the missing add-on, and a publish at its
first call, because a service that only publishes cannot be told apart at build time.

The in-memory stores, `snodra.NewMemoryEventStore()` and `snodra.NewMemoryMessageStore()`, are not durable and are for
tests and local runs; `Start` warns once for each. The [add-ons pages](/docs/add-ons/) list the artifacts, settings,
guarantees and capabilities of each store.

### Transactions

A message store implements `Begin(ctx) (context.Context, Tx, error)`. `Publish` and the consumer's marker use the
transaction the context carries; the service's own writes join it through the store's own helper:

- **SQL.** `store.Tx(ctx)` returns the `*sql.Tx` a handler received, `store.WithTx` binds a transaction the service
  began, and `store.WithConn` binds a connection the service keeps in one. A pool with at least two connections is
  required; the default is ten.
- **MongoDB.** `store.Session(ctx)` returns the session a handler received and `store.WithSession` binds one the
  service began. The database must be a replica set.

Outside any transaction, a store call runs in a short transaction of its own. A transaction that is neither committed
nor rolled back keeps its write reservations until the process ends; commit or roll back every one.

### Event errors

| Error | Meaning |
|---|---|
| `ErrInvalid` | the event or a store argument is invalid: a payload that is not a JSON object, an integer too large, a missing setting. Nothing was appended |
| `ErrRejected` | the event store will never take the event; the relay gives it up at once |
| `ErrFailed` | the event store failed; another try may succeed, and the relay retries within its attempts |
| `ErrConflict` | another writer got to the record first; the caller retries the operation as a whole, in a new transaction |
| `ErrUnsupported` | the port or the operation is not implemented at this level |

The add-on's own errors wrap these, so `errors.Is` works across the stores.

## Not in the Go library yet

Sagas (feature level 4) are not in the Go library. The level-3 APIs — processor status and control (pause and resume,
reset and replay), dead letters, `HandleReset` and `ResetContext` — are implemented and are documented with the
level-3 release. The library has no event browser either, so its event-store add-ons declare no `browse` capability. For
sagas, use the [Kotlin](/docs/messaging/kotlin/) or [Rust](/docs/messaging/rust/) library.

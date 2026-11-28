---
title: "API"
---

The package is `snodra`, imported as `snodra "github.com/snodra/snodra-messaging-go"`. `go doc -all` on it is the
complete reference; this page is the tour. Every snippet below is compiled by the library's tests, except the
level-3 handlers, which call the service's own store and mail functions, and the saga and adapter sketches, which are
condensed from the library's saga and external-call tests.

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
go get github.com/snodra/snodra-messaging-go/observability@v0.7.0
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
instead of handled twice. An event type the processor has no handler for is acknowledged and runs nothing. A record
without a `type` header, or whose payload is not a JSON object for a type the processor handles, can never be handled:
in mode `collection` it is parked as an `INVALID` letter, in `event-store` it is published to the dead-letter source,
and in `log` it is logged and skipped. A payload that does not decode as the handler's type is not retried either: in
`collection` it is parked as a `HANDLER_FAILED` letter with `InvalidMessage` as its error type, and in the other modes
it is published or logged like any other exhausted record. A handler that fails is tried up to
`SNODRA_CONSUMER_MAX_ATTEMPTS` times (5 by default), the first included, one second apart; after that the record
becomes a dead letter, according to [`DeadLetterMode`](#dead-letters). A subscription that fails is reopened after 1 s,
doubling up to 30 s, and the wait starts over after a delivery or a subscription that lived 30 s.

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

## Processor status

Every status report (`SNODRA_SERVER_STATUS_INTERVAL_MS`, 5 s by default) carries one `ProcessorStatus` per processor
that has started on this instance, and the whole list every time. The status is built from memory and never waits on the
event store, the message store or a handler, so it cannot delay a tick or a consumer. The hub shows it in its topology,
`GET /api/v1/processors` and the dashboard's Processors page; this library has no local status method.

| Field | Content |
|---|---|
| `name`, `subscription`, `source` | the processor, its subscription `<service>.<processor>`, and the event store's source |
| `state` | `PROCESSOR_STOPPED` while its consumer does not run (stopping, or out of its subscription for a reset, with `operation_id` set); else `PROCESSOR_PAUSED` while [paused](#pause-and-resume); else `PROCESSOR_FAILING` for 60 s after a record exhausted its attempts, a letter could not be parked or the subscription reported an error; else `PROCESSOR_STARTING` before the first assignment and between a `Revoked` and the next `Assigned` (an empty assignment counts as assigned: such an instance is running); else `PROCESSOR_RUNNING` |
| `segments` | the assignment, sorted by `SegmentOrder`; per segment `position` (the next position this instance delivers), `committed` (after its last acknowledgement), `head` and `lag` (`committed` to `head`, `position` to `head` without a commit; `-1` when unknown, never negative otherwise), and `replay_until` while an open replay range has not been passed |
| `processed_total`, `failed_total` | records whose delivery completed, a skipped duplicate included, and records that exhausted their attempts, since start (`SEQUENCED` and `INVALID` letters count in neither) |
| `dead_letters` | `DeadLetterStore.Count` at start, every 30 s and right after this instance parked a letter; `0` unless the mode is `collection` |
| `last_error`, `last_error_at_ms` | the last failure's error message (a plain `err.Error()`, with no type prefix), never the payload, cut at 512 bytes |
| `event_types`, `dead_letter_mode` | the types with a handler in the processor, sorted; the [dead-letter mode](#dead-letters) |
| `operation_id` | the reset operation holding the processor's lock, empty when none |
| `replaying` | an open replay range on this instance's subscription has not been passed |
| `event_store`, `capabilities` | the event store's `Name()` and its `Capabilities()`, distinct and sorted, each within the protocol's 64-byte name bound |

## Processor control

The hub is the control plane: its dashboard and HTTP API pause, resume and reset a processor on every instance, and
work its dead letters (see [the hub's processor control](/docs/server/processor-control/), which owns the routes and
the write credential). The hub keeps nothing. Each processor's pause, reset lock and replay ranges live in the service's
message store, in the processor-control port, which every instance reads once at start and then every 5 s; a
`ControlRequest` is only the fast path, and an instance that missed one converges on its next poll.

Every request is handled off the hub stream's read loop, one at a time per processor, in arrival order, and answered
with **exactly one** `ControlReply` carrying the request's `control_id`, on the stream the request arrived on (a
reply for a stream that is gone is dropped and logged at debug). An unknown action is `CONTROL_REFUSAL_INVALID`; a
processor this instance does not run is `CONTROL_REFUSAL_UNKNOWN_PROCESSOR`; a panic or a store failure inside an
action is `CONTROL_REFUSAL_FAILED`. Every action is logged at INFO with its control id, processor, action and result.
The actions are `pause`, `resume`, `reset_prepare`, `reset_execute`, `reset_finish`, `dead_letter_list`,
`dead_letter_retry`, `dead_letter_retry_all` and `dead_letter_discard`; a refusal is one of `INVALID`, `LOCKED`,
`NOT_PREPARED`, `SUBSCRIBERS_ACTIVE`, `RESET_HANDLER_FAILED`, `UNKNOWN_PROCESSOR`, `NOT_FOUND`, `UNSUPPORTED` or
`FAILED`, with a message cut at 512 bytes.

### Pause and resume

A pause is written to the message store first, with the request's control id as its author (`local` for a local
write), and then applied here: the processor's subscription stops delivering **without leaving it** (the event store
keeps the assigned segments, and a record fetched before the pause comes again on the resume), and the status reads
`PROCESSOR_PAUSED`. A resume clears the stored pause and delivers from where it stopped. The state is idempotent, so a
repeated pause is not an error.

A processor that starts while the stored state says paused starts paused; it reads the state before it subscribes, so a
pause is never missed between a restart and the first poll. A message store without the processor-control port leaves
its processors running unpaused and cannot persist a pause.

A pause stops subscription delivery only: dead-letter actions keep working (a retry runs the handler directly), and the
status tick, the control queue and the rest of the library are unaffected. A reset lock is separate from a pause: a
reset leaves the processor stopped, and the finish resumes consumption still paused if it was paused before.

## Reset and replay

A reset moves the subscription of a processor to a new position as a **leased operation**, in three control actions.
The state lives in the message store's `processor_control` state (the `snodra_processor_control` table in SQL, the
`processor_control` collection in MongoDB, one row or document per processor): its pause, its operation
`{id, kind: "reset", lease_until, prepared_at}`, and its open replay ranges. `ProcessorControlStore` is the port
(`Get`, `SetPaused`, `Lock`, `Extend`, `Release`, `Expire`, `SetReplay`, `RemoveRange`), and `ProcessorControlState`,
`ControlOperation` and `LockOutcome` are its values; every write is a write of its own, outside any transaction.

1. **Prepare.** `reset_prepare` takes the processor's lock for the operation id until the requested lease (at least
   1 s) and leaves the subscription: the consumer cancels its subscription and waits until it has left it (a record
   still in flight is not acknowledged and comes again after the reset), and the status reads `PROCESSOR_STOPPED` with
   `operation_id`. Preparing the same operation again renews its lease; another operation holding an unexpired lease is
   `CONTROL_REFUSAL_LOCKED`, and an operation that already ended on this instance is
   `CONTROL_REFUSAL_NOT_PREPARED`. An instance that starts, or polls, while a foreign lock it was not prepared for is
   unexpired keeps out of the subscription too.
2. **Execute.** `reset_execute` must be answered by the instance that prepared the operation (`NOT_PREPARED`
   otherwise). The event store's admin plans the target per segment; a plan with members still reading is
   `CONTROL_REFUSAL_SUBSCRIBERS_ACTIVE` and nothing changes. Then, in this order: the processor's reset handlers (only
   when something replays), the deletion of its stage-1 markers in the ranges, the ranges written to the state, a
   second check that no instance reads the subscription, and the commit of the new positions. The execute renews its
   lease every 10 s (at most a third of it) and refuses with `FAILED` "lease lost: ..." after 120 s or when the lease
   cannot be renewed, before moving anything more. Its reply carries the ranges, the markers deleted and the number of
   reset handlers that ran.
3. **Finish.** `reset_finish` releases the lock, remembers that the operation ended on this instance and consumes
   again, still paused if it was paused before. A finish for an operation nothing holds is OK (it never claims to have
   released a lock); another operation's lock is `NOT_PREPARED`. A late renewal after the finish never takes the lock
   again: an operation that ended here (finished, aborted, its lease passed or its lock lost) is remembered for at
   least `max(2 x lease, 60 s)`, at most a day, and a prepare or renewal of it is refused `NOT_PREPARED`.

A hub that dies mid-reset stops renewing: the lease passes, and every instance releases the operation on its next poll
(`Expire`) and consumes again by itself; an execute in flight gives up at its limit and refuses. A refusal after the
reset handlers ran is **not "nothing changed"**: their effects stay, and the message says what else happened, for
example `reset handlers ran (2), 37 markers deleted, replay ranges written, positions not moved: retry the reset`.

**Targets.** `ResetEarliest` moves every segment to its first position (everything the event store still keeps is a
replay); `ResetLatest` moves it to its head (nothing is replayed); `ResetTimestamp{TimestampMs}` to the first position
appended at or after that time (else the head); `ResetPositions{Positions: []SegmentPosition{{"0", "42"}}}`
moves the listed segments, each once, and leaves a segment it does not list at its committed position. An
unknown segment or a position past the head is `INVALID`. These are the same values the hub's reset target carries,
and an add-on's `SubscriptionAdmin.Plan` returns one `ReplayRange` per segment it addresses.

**Ranges and replay.** A `ReplayRange{Source, Segment, From, Until}` means the records of `Segment` at positions
`From` (inclusive) to `Until` (exclusive) are a replay; `From` is the target, `Until` the subscription's committed
position before the reset (empty when it had none). Only a range with `Until` set and `From` before it replays
anything; `latest` makes none. In a replay the processor's handlers run again except those registered with
`DisallowReplay()`, the stage-1 marker is still recorded (and the record acknowledged), and the sagas are never run.
The range closes once the committed position of a segment this instance holds (or its next
position while nothing is committed) reaches its `Until`: the instance removes it from the state, and the status stops
showing `replaying`; another instance's range is left to that instance. A reset never touches the dead letters.

```go
// Once per reset that replays anything, on the instance that executes it, before any marker
// or position moves. An error (or a panic) stops the reset with RESET_HANDLER_FAILED; the
// handlers that ran have run.
err := snodra.HandleReset(app, "orders", func(ctx context.Context, reset snodra.ResetContext) error {
	if _, whole := reset.Target.(snodra.ResetEarliest); whole {
		return orders.DeleteAll(ctx) // the projection is rebuilt from the replay
	}
	return nil
})

// Never again in a replay: an effect outside the database.
err = snodra.HandleEvent(app, func(ctx context.Context, e OrderPlaced) error {
	return mail.Confirm(ctx, e)
}, snodra.InProcessor("orders"), snodra.DisallowReplay())
```

`HandleReset` registers before `App.Start` (like every handler; a late call is `ErrRegistrationClosed`), takes the
`default` processor or a name matching `[a-z0-9][a-z0-9-]{0,47}`, and runs its handlers in registration order. A
processor with a reset handler must also have an event handler, or `Start` fails: no reset of it could ever run.
`ResetContext` is `{Processor string, OperationID string, Target ResetTarget, Ranges []ReplayRange}`; `Ranges` is never
empty when the handlers run.

## Dead letters

A record a processor cannot handle is kept, not only logged. `DeadLetterMode` (`SNODRA_DEAD_LETTER_MODE`) chooses
where it goes:

| Mode | What happens | Sequenced per key | Hub control |
|---|---|---|---|
| `collection` (default) | parked in the message store's dead letters (`dead_letters` in MongoDB, `snodra_dead_letters` in SQL), then the record is acknowledged | yes | list, retry, retry-all and discard |
| `event-store` | published to the event store's dead-letter source `<source>.dlt` (`DeadLetterSource`), which needs `CapabilityNativeDeadLetter`; the record is acknowledged once the store took it. **The topic or stream must exist** | no | none (the destination is the operator's) |
| `log` | logged (never the payload) and skipped | no | none |

The three reasons, per processor and stage 1 only:

- `DeadLetterHandlerFailed` (`HANDLER_FAILED`): the processor's handlers failed on every attempt (`Attempts` is the
  invocations made; one for a payload the type cannot be read from). It blocks its key.
- `DeadLetterSequenced` (`SEQUENCED`): the record's key has an earlier letter in this processor; it is parked without
  running the handlers, and `BlockedBy` names the key's head letter. A record without a key is never sequenced. It
  blocks its key.
- `DeadLetterInvalid` (`INVALID`): no `type` header, or a value that is not a JSON object for a type the processor
  handles. It blocks nothing and can only be discarded. A type no handler of the processor knows is skipped, not a
  letter.

A letter's id is `LetterID(processor, source, segment, position)`, that is
`<processor>:<source>:<segment>:<position>` (`<processor>:<topic>:<partition>:<offset>` on Kafka), so a redelivered
record finds its own letter and is acknowledged instead of parked twice. A letter has `ParkedAt`, `LastAttemptAt` and
`ExpireAt` (30 days after it is parked; the store's retention removes it), and its `Replay` flag says it was parked
while its processor replayed the record, so its retry is a replay too. The document keeps the record's `Key`, `Headers`,
`EventID` (the `id` header), `EventType` (the `type` header) and `Payload` byte for byte.

In `event-store` mode the published event carries the record's key, value and headers (minus the six the library
writes) and six `snodra-dlt-*` headers: `snodra-dlt-processor`, `snodra-dlt-reason`,
`snodra-dlt-error` (`<type>: <message>`, at most 2000 characters), `snodra-dlt-original-topic`,
`snodra-dlt-original-partition` and `snodra-dlt-original-offset`.

**Working the letters through the hub.** These actions answer only in mode `collection`; in `event-store` and `log`
every one is refused `INVALID` ("there is nothing to list, retry or discard").

- `dead_letter_list` takes a limit of 1 to 100 and answers the oldest letters first, without payloads or headers, with
  the processor's total count.
- `dead_letter_retry` retries one letter: the processor's handlers for its type run in stage 1 under the record's
  marker, and the letter's deletion is in the same transaction, so a failure keeps the letter (`Attempts + 1`, the new
  `Error` and `LastAttemptAt`, reason `HANDLER_FAILED`) and a crash can neither handle it twice nor handle it and keep
  it. The outcome is `Retried`, `Duplicate` (a marker existed already: the letter is deleted), `Failed`, `Blocked`
  (the key's earlier letter must go first; the detail names it), `NotRetriable` (`INVALID` or no event type) or
  `NotFound`. No back-off; the sagas are not re-run.
- `dead_letter_retry_all` goes per key in position order, keys by their head letter's `ParkedAt`, a key stopping at its
  first failure (its later letters count as `blocked`), then the keyless letters by `ParkedAt`; `INVALID` letters are
  `skipped`. It answers the counts `retried`, `failed`, `blocked` and `skipped`.
- `dead_letter_discard` deletes a letter (`NOT_FOUND` when it is gone); discarding a key's head unblocks its next
  letter. A letter that expires unblocks its key too.

A retry reaches only the processors this instance runs; a letter of another processor is `NotFound` (retry) or
`NOT_FOUND` (discard). `DeadLetterStore` is the port an add-on implements (`Park`, `Head`, `Earlier`, `ParkedKeys`,
`Get`, `List`, `Summaries`, `Count`, `Delete`, `DeleteIn`, `RecordFailure`); the in-memory message store implements it
and the control state, for tests.

## Sagas and deadlines

A saga is a long-running process that reacts to events, keeps its own state, sends commands and events, waits, and
ends. It is the saga model of the Kotlin and Rust libraries, for integrations with external systems: the saga records
what it wants done, a relay sends it after the transaction commits, and the external system's answer comes back as an
event or as the local `SagaCommandFailed` notice. A saga runs inside the service, against its message store and its
event-store consumer; the hub only carries the commands it sends to another service. Sagas run in the `default`
processor only.

```go
// The state is persisted as its JSON object after every handled message; it must round-trip
// from its zero value through the codec.
type OrderSagaState struct {
	OrderID string `json:"orderId,omitempty"`
	Step    string `json:"step,omitempty"`
}

err := snodra.HandleSaga(app, "orders", func(d *snodra.SagaDefinition[OrderSagaState]) {
	d.StartOn(snodra.StartedOn(
		snodra.Associate("orderId", func(e OrderPlaced) string { return e.OrderID }),
		func(ctx context.Context, saga *snodra.SagaContext, state *OrderSagaState, e OrderPlaced) error {
			state.OrderID = e.OrderID
			if _, err := saga.Schedule(15*time.Minute, "charge-timeout", nil); err != nil {
				return err
			}
			return saga.Send(ChargeCard{OrderID: e.OrderID}, e.OrderID)
		}))
	d.OnDeadline(snodra.Deadline("charge-timeout",
		func(ctx context.Context, saga *snodra.SagaContext, state *OrderSagaState, _ any) error {
			state.Step = "timed-out"
			return saga.Publish(OrderPaymentFailed{OrderID: state.OrderID}, state.OrderID)
		}).Ending())
	d.OnCommandFailed(snodra.CommandFailed(
		func(ctx context.Context, saga *snodra.SagaContext, state *OrderSagaState, failed snodra.SagaCommandFailed) error {
			state.Step = string(failed.Reason)
			return saga.Publish(OrderPaymentFailed{OrderID: state.OrderID}, state.OrderID)
		}))
})
```

The definition:

| Element | Meaning |
|---|---|
| `HandleSaga[S](app, name, define)` | Registers the saga; `S` is the state. The name is unique and cannot contain `:` (the marker and dispatch-entry ids use it). A definition error names the saga and handler and is returned here and by `Start`. |
| `d.StartOn(StartedOn(route, handler))` | A handler that may create an instance. The event starts one when no live instance of the type matches any handler for it; at most one live instance exists per start key. `.ForceNew()` always starts one, without a start key. |
| `d.On(HandledOn(route, handler))` | A handler of an event on the live instances associated with the route's key and value. |
| `d.OnDeadline(Deadline[S, P](name, handler))` | A handler of deadlines named `name`; it receives the payload as `P` (the zero value when there is none). One handler per name. `.Ending()` ends the instance after it. |
| `d.OnCommandFailed(CommandFailed(handler))` | The handler of the local `SagaCommandFailed`; it is routed to the sending instance by its `SagaID`, no association needed. |
| `.Ending()` on an event or deadline | Ends the instance after the handler returns; later handlers of that event do not run. |
| `Associate(key, value)` | The route: the event's value for `key`. A nil value function is a registration error; an empty value matches no instance, while a whitespace-only value is a value like any other. |

A handler is `func(context.Context, *SagaContext, *S, E) error` (the deadline payload `P` replaces `E`). Handlers of
one event type run in registration order. The state is stored as JSON: it must encode to a JSON object and encode to
the same text after a decode, or registration fails. A handler runs synchronously on the consumer and holds its
goroutine and the partition; keep it to recording, not I/O. A panic is a handling failure, never a crashed process.
`MessageFrom(ctx)` describes the delivered event, or a deadline's synthetic `deadline:<name>` message with empty
headers and the correlation id of the message that scheduled it.

`SagaContext` is the only supported way to act from a handler:

| Call | Meaning |
|---|---|
| `SagaID()`, `CorrelationID()` | The instance id and the correlation id of the message being handled. |
| `Associate(key, value)`, `RemoveAssociation(key, value)` | Add or remove an association. Removing the start association frees the start key. |
| `End()` | Ends the instance after the handler returns and cancels its scheduled deadlines. |
| `Send(command, routingKey)`, `Publish(event, key)` | **Record** a command or event in the saga's transaction, sent after the commit, in order. `Publish` also refuses at record time an event the outbox could never hold. |
| `Schedule(after, name, payload)`, `ScheduleAt(at, name, payload)` | Record a deadline; both return its id. The payload is JSON with its type name. |
| `CancelDeadline(id)`, `CancelDeadlines(name)` | Cancel a deadline, or every scheduled deadline of that name. |

A handling records at most 999 messages. Nothing is sent or published while the handler runs. The package-level
`Send`, `Query` and `Publish` are refused with an error naming `SagaContext` while a saga handler runs; use the
context, and do not capture the `*App` to call them later for the same reason.

**Start keys and matching.** A start key is `"<type>|<key>=<value>"` with `%`, `|` and `=` escaped. It lives with its
association: removing that association, or ending the instance, releases it, so a later start event for the same value
creates a new instance. The first start handler in registration order whose association value is present creates the
instance; the new instance then runs every handler of that event whose key and value are that association.

### Stage 2

The saga stage runs in the `default` processor **after** stage 1 committed, and also when stage 1 failed, decoded the
wrong type or exhausted its attempts. The record is acknowledged only after both stages. Stage 2 also sees a record
parked `SEQUENCED` behind an earlier dead letter (stage 1 never ran) and a record whose own letter exists after a
crash. A record inside an open replay range is skipped: a replay never runs a saga again.

Per (event, saga type), one message-store transaction:

1. inserts the marker `saga:<type>:<eventId>` (a conflict retries the event, it is not a duplicate);
2. resolves every live instance of the type by each handler's association;
3. runs the matching handlers in registration order, in one transaction with the state writes, the dispatch entries
   and the deadline changes;
4. commits, then acknowledges the record.

The marker is committed even when no instance matched. The state uses optimistic version 0 at creation and `+1` per
write; a version or start-key conflict retries the event up to 5 attempts (200 ms doubling to 5 s, jittered), and a
handler failure gets 2 quick attempts. An event that fails every attempt is parked in `saga_failures` with its marker
and the consumer moves on; a store failure while parking leaves the record unacknowledged.

### The dispatch relay

Every instance runs the relay. It polls every 500 ms: failure notices due first, then the sagas whose first pending
entry is due, at most 100 sagas per poll and 4 at a time. One saga's entries go strictly in `seq` order under a lease:
the base is 30 seconds, and while a relay owns a saga it claims and renews 1 minute + 11 seconds + 30 seconds =
**101 seconds** with the defaults, covering the send bound and the hub guard, so another instance cannot take the saga
while a send may still run. A slow or retrying saga holds back only itself. Different sagas are dispatched at the same
time.

- **An event entry** is appended to the ordinary outbox and marked dispatched in one transaction, with a fresh event
  id, the entry's key, the recording message's correlation id and a valid trace. An event the outbox refuses is given
  up at once as `INVALID`, with no notice, and the later entries go on.
- **A command entry** is sent by its wire type with its stored JSON, routing key, `idempotency-key`
  (`<sagaId>:<seq>`) and `saga-id`, the recording message's correlation id and trace, and **no authorization** or
  caller identity. A type the service handles itself goes to its own handler unless `AlwaysRouteThroughHub` is on;
  otherwise it goes through the hub. The sender uses `NoRetry`: the relay owns every retry.
- **At least once.** An entry is marked dispatched after its reply. A crash in between sends it again with the same
  idempotency key, so every handler of a command a saga sends must be idempotent by `idempotency-key`.
- **The send bound.** A send is waited for at most 1 minute; a call through the hub is waited out for the hub's guard
  (11 s) too, so it is not resent while a hub may still run it. A local handler that honours its context and returns
  after it ended is an unknown outcome and is retried with the same key. A handler that ignores its context cannot be
  stopped by Go; its goroutine may outlive the relay's wait, which the relay abandons at the bound.

A failed attempt is classified as **transient** or **permanent**:

| Transient (retried) | Permanent (notice at once) |
|---|---|
| never sent; unknown outcome; hub `NO_HANDLER`; `TIMEOUT`; `HANDLER_DISCONNECTED`; `RESOURCE_EXHAUSTED`; `{"snodra":"retryable"}`; a non-messaging sender failure | local `UNAUTHENTICATED`/`PERMISSION_DENIED` (`DENIED`); `INVALID_REQUEST` (`INVALID`); `{"snodra":"unknown-outcome"}` (`UNKNOWN_OUTCOME`); any other `HANDLER_ERROR` or `CANCELLED` (`FAILED`) |

A transient failure waits 1 s, doubling to 5 minutes (±20 %), 10 attempts in all, then becomes `EXHAUSTED`. The failure
and its pending notice are written in one `MarkFailed` before the notice is delivered, and the saga's later entries are
still sent: the saga decides what a failure means. A permanent failure is recorded at once.

### `SagaCommandFailed`

`SagaCommandFailed` is the local event `snodra.SagaCommandFailed` with `SagaID`, `CommandType`, `IdempotencyKey`,
`Reason` and `Message`; its id is `failed:<sagaId>:<seq>` and it carries the command's correlation id. The runtime
routes it to the live instance of its type that handles it, by `SagaID`, without an association, and also runs any
ordinary `HandleEvent` handler the service has for the type. It is **never** appended to the outbox or published to the
event store.

| Reason | When |
|---|---|
| `NO_HANDLER` | Nobody handles the command type in a service without a hub. A Go service always has a hub, so this reason is only read from records written by another library; a hub's `NO_HANDLER` is transient and ends as `EXHAUSTED`. |
| `DENIED` | The handler requires an authenticated caller (or denies the caller): a saga command has no caller. |
| `INVALID` | The handler could not read the payload. |
| `FAILED` | The handler failed with any other error, including an idempotent adapter's permanent failure. |
| `UNKNOWN_OUTCOME` | An idempotent adapter cannot tell whether its external call happened. |
| `EXHAUSTED` | A transient failure lasted through all 10 attempts. |

A notice that cannot be delivered is retried on the command backoff and given up after 10 attempts, logged at error; a
notice nobody handles is logged at error. A permanently failed command does not hold back the saga's later entries.

### Deadlines

`Schedule`/`ScheduleAt` and the cancel operations are recorded in the saga's transaction. Every instance runs a
scheduler every second: it claims each due deadline with a 30-second lease, then runs the handler, writes the state,
its dispatch entries and the deadline changes, and marks the deadline fired, all in one transaction. A deadline no
longer scheduled is left alone; one whose saga ended, is gone or has no handler of that name is cancelled. A failed
firing retries like an event and leaves the claim to expire, so the deadline fires again after the lease: **at least
once**, never before its due time, never for a cancelled deadline or an ended saga. Ending the instance cancels its
scheduled deadlines. A deadline handler's context has empty headers, the scheduling message's correlation id and no
trace; the commands it records carry that correlation and no trace header.

Leases are timestamps written by one instance and compared with another instance's clock: keep the instances' clocks
in step (NTP or the platform's time sync).

## Idempotent external calls

`HandleIdempotentCommand` makes a command handler safe to call again with the same key: each call is recorded in the
message store's `external_calls` before the body runs.

```go
err := snodra.HandleIdempotentCommand(app, func(ctx context.Context, cmd ChargeCard) (ChargeReceipt, error) {
	info, _ := snodra.MessageFrom(ctx)
	receipt, err := gateway.Charge(ctx, cmd.OrderID, info.Headers["idempotency-key"])
	switch {
	case errors.Is(err, gateway.ErrUnavailable):
		return ChargeReceipt{}, snodra.Retryable(err)       // nothing was charged: try again later
	case errors.Is(err, gateway.ErrAmbiguous):
		return ChargeReceipt{}, snodra.UnknownOutcome(err)  // it may have charged
	case err != nil:
		return ChargeReceipt{}, err                          // permanent: replay the stored error
	}
	return receipt, nil
}, snodra.ExternalIdempotent())
```

- **The key** is the `idempotency-key` header. A saga's relay sets it to `<sagaId>:<seq>`. A missing or blank key is a
  plain `HANDLER_ERROR` naming the command and the header, before any record or body. The key is the header only: the
  library does not evaluate a typed key expression (the Kotlin library's `@IdempotentHandler(key = ...)`).
- **The record lifecycle.** The first call inserts `IN_PROGRESS` with a fresh owner and a 5-minute lease; the first
  insert wins. A concurrent call sees the owner's in-flight record and is answered with the retryable marker. A repeat
  after `SUCCEEDED` returns the stored reply bytes without running the body. `FAILED` replays its stored message.
  `UNKNOWN` reports the unknown-outcome marker again.
- **A lapsed call.** An `IN_PROGRESS` record past its lease is given up as `UNKNOWN` by default, or taken over and
  run again with `ExternalIdempotent()` (the partner de-duplicates by the key). If the record changed between the read
  and the write, the write fails and the call reads again (three rounds at most), so a slow call's success is returned
  rather than overwritten.
- **Settlements are owner-conditional.** A body failure with `Retryable` calls `Reset` (the next call runs the body
  again; the relay owns the backoff), `UnknownOutcome` calls `MarkUnknown`, and any other error stores `FAILED` with
  the `HANDLER_ERROR` JSON and is returned unchanged. A settlement matches the owner token, so a call whose lease ran
  out never overwrites the record of the call that took it over.
- **A panic** in the body is recovered: the record is settled `UNKNOWN` (the external call may have happened) and the
  caller gets the unknown-outcome marker, not a plain failure. This is a deliberate divergence from Kotlin, which
  settles `FAILED`; the safe answer is that the outcome is unknown.
- **An unrecorded success** (the body returned but its reply could not be encoded, or the `SUCCEEDED` write failed) is
  never reported as success: with a de-duplicating partner it is the retryable marker and the record stays
  `IN_PROGRESS`; otherwise the record is marked `UNKNOWN` and the caller gets the unknown-outcome marker.
- **Store failures before the body** (`Insert`, `Find`, `TakeOver`, `Expire`) are a plain permanent `HANDLER_ERROR`,
  as in Kotlin; the body never runs and a saga records `FAILED`.
- **The records are their own short writes**, outside the caller's transaction: a rolled-back caller never forgets a
  call that happened. The adapter never retries a call itself; the saga relay owns the retry.
- **The markers.** `Retryable(err)` and `UnknownOutcome(err)` answer `HANDLER_ERROR` with details exactly
  `{"snodra":"retryable"}` or `{"snodra":"unknown-outcome"}`, whatever they wrap. `IsRetryable` and `IsUnknownOutcome`
  read the marker from a local handler error or a hub `*Error`, trimming surrounding whitespace as the relay does. A
  marker wrapped in another error is found too.
- **Startup.** The handler needs a message store and its external-calls port: `Start` refuses a service without
  either, names the port for an `ErrUnsupported` store, and probes it after schema preparation. An
  idempotent-command-only service needs no event store.
- **Commands only.** There is no idempotent event-handler adapter; wrap an external call in an idempotent command.

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
key, at-least-once delivery with acknowledgement, pause and resume, the headers as the store's native metadata, and the
admin side of a reset (`Admin`, `Members`, `Plan`, `Apply`). The message-store interface is frozen through level 4: its
outbox, processed-event, dead-letter, processor-control, external-call and saga ports are implemented by both official
stores (the dead-letter and control ports since `v0.6.0`, the external-call and saga ports since `v0.7.0`), which pass
the eleven level-4 store checks. A third-party add-on implements the same interfaces and depends on the core only;
`snodratest` is its conformance kit (see [Testing](/docs/messaging/go/testing/)).

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

## Limits and differences

The library is at feature level 4, with these documented limits:

- **No event browser.** Its event-store add-ons declare no `browse` capability, and its event-store kit omits the four
  positive `browse` checks while running `no_browser_without_capability`.
- **No permanent local `NO_HANDLER`.** Go has no hubless service mode (`New` requires a hub), so a command type the
  service does not handle goes to the hub; a hub's `NO_HANDLER` is transient and ends as `EXHAUSTED`. The
  `NO_HANDLER` notice reason is kept for records written by another library.
- **The adapter key is the header only.** There is no typed key expression like Kotlin's
  `@IdempotentHandler(key = ...)`; a key derived from the message must be set as `idempotency-key` by the caller.
- **An adapter panic is an unknown outcome.** The record is settled `UNKNOWN` and the caller gets the
  unknown-outcome marker, not Kotlin's `FAILED`; the call may have happened.
- **Commands only.** `HandleIdempotentCommand` is the idempotent adapter; there is no idempotent event-handler adapter.
- **No saga or external-call metrics.** The telemetry interface has no counters for them; the outcomes are in the
  store and the logs. The core otherwise keeps the Kotlin and Rust metric names.
- **No local admin API for parked saga events.** They are in the message store's `saga_failures` records; the
  Go library has no `SagaFailures` list/retry/discard helper like Kotlin's or Rust's.
- **The level-4 clocks are fixed.** The saga stage, relay, deadline scheduler and external-call lease use the
  reference values, with no `SNODRA_*` variable or option yet ([Configuration](/docs/messaging/go/configuration/#sagas-deadlines-and-external-calls)).
- **Leases need synchronised clocks.** The dispatch lease, the deadline claim and the external-call lease compare one
  instance's timestamp with another's; keep the clocks in step.

For a language-specific API, see the [Kotlin](/docs/messaging/kotlin/) and [Rust](/docs/messaging/rust/) pages.

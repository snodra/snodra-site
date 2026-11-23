# API

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
  `TIMEOUT`.
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
`Stream` or `Gather` of it, and a `Subscribe` of a type nobody serves with `HandleSubscription`, fail with
`INVALID_REQUEST`. A subscription takes no permit and no handler slot, and `MaxSubscriptions` bounds
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
go get github.com/snodra/snodra-messaging-go/observability
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
request's `traceparent`, and the requests the handler sends carry its trace context.

## Not in the Go library yet

Events, event stores, message stores, the outbox, event processors, dead letters and sagas (feature levels 2 to 4) are
not in the Go library. Use the [Kotlin](../kotlin/index.md) or [Rust](../rust/index.md) library for them.

---
title: "Testing"
---

## Testing your handlers

A handler is a plain function, `func(context.Context, C) (R, error)` (an event handler returns only its error), so a
service tests it as one: call the function with a context and a message and check the result and the error. Keep the
function apart from the registration (a named function or a method, passed to `HandleCommand` or `HandleEvent`) so
that a test can reach it.

An event handler is tested the same way. A test that wants the outbox and the markers can use the in-memory stores:
`snodra.NewMemoryMessageStore()` and `snodra.NewMemoryEventStore()` are complete stores with no infrastructure, for
tests only. They are not durable, and `Start` warns when one is active.

The library's own scripted hub, `internal/fakehub`, is an internal package: Go does not let another module import it.
A service does not need it. To test the wiring against a real hub, run the hub image (`snodra/snodra-server`, see the
[Hub quick start](/docs/server/quickstart/)) and point the service at it with `SNODRA_SERVER_ADDRESS`.

## The library's own tests

The library's unit tests need no Docker and run against an in-process scripted hub, in the core module and in
`observability/`:

```sh
go test -race ./...
```

The add-on modules are separate modules, each with its own tests:

```sh
cd kafka    && go test -race ./...   # a Kafka broker
cd rabbitmq && go test -race ./...   # RabbitMQ with the stream and management plugins
cd mongo    && go test -race ./...   # a MongoDB replica set
cd sql      && go test -race ./...   # PostgreSQL and MySQL
```

Their integration tests use Testcontainers, with every image pinned by digest; without a working Docker they skip and
the unit tests still run. The SQL module runs its suite on both PostgreSQL and MySQL. The workspace (`go.work`)
builds each add-on against the core in this checkout.

## The add-on kits

`snodratest` is the conformance kit for add-ons; it imports only the standard library and the core, so an add-on
depends on the core, never the reverse. An add-on runs the kit from its own test:

```go
func TestMyEventStore(t *testing.T) {
	snodratest.EventStore(t, "snodra.events",
		func() snodra.EventStore { return newMyEventStore(t) },
		markers.Processed())
}

func TestMyMessageStore(t *testing.T) {
	snodratest.MessageStore(t, func() snodra.MessageStore { return newMyMessageStore(t) })
}
```

`snodratest.EventStore` runs the nine level-2 event-store checks (`headers_round_trip`,
`same_key_arrives_in_publish_order`, `every_processor_gets_every_event`, `instances_share_a_processor`, and the rest of
the list on the [event-store contract](/docs/library-authors/event-store-add-ons/#the-conformance-kit));
`snodratest.MessageStore` runs the nine outbox and processed-event checks. Each check is a subtest named exactly as the
Rust kit names it, and every check is exported, so a failing one can be run by itself. The capability checks (replay,
lag, dead letters and browse) and the processor checks come with level 3.

`snodratest` has no Docker and no store client. The add-on's own test provides the store and the infrastructure; the
kit only proves the contract.

## The conformance runner

The language-neutral [conformance runner](/docs/tools/conformance-runner/) proves feature level 1. The library ships
its service for it, `examples/conformance-service`, written on the public API only; the runner drives it against
scripted hubs and a real one. `scripts/conformance.sh` in the repository runs the whole thing, and needs Docker:

```sh
scripts/conformance.sh                       # the 33 level-1 checks, a hub from the snodra/snodra-server image
scripts/conformance.sh --only L1-RETRY       # one check
SNODRA_HUB_PORT=17000 scripts/conformance.sh # when port 7000 is taken (the second hub is 100 above)
```

The script builds the service, downloads the pinned runner release into `bin/` and checks it against the sha256 pinned
in `scripts/conformance-runner.sha256` (or uses the runner that `SNODRA_CONFORMANCE_BIN` names), starts the hub
(`SNODRA_SERVER_VERSION` picks the image tag) and removes it afterwards. On macOS the AirPlay Receiver holds port 7000,
so set `SNODRA_HUB_PORT` there. CI runs the same script with the same pinned runner, fails when a check fails or is
skipped, and keeps the runner's report as a build artifact.

The runner proves level 1 only; level 2 is proved by the add-on kits above and by the library's own tests of the
outbox, the relay and the consumer. The checks and what each asserts are listed in
[Feature levels](/docs/library-authors/feature-levels/) and in
[Conformance](/docs/library-authors/conformance/).

## Levels 3 and 4

The Go library has no processor status, processor control, dead letters or sagas yet, so there are no level-3 or
level-4 kits to run for it. The ports exist in the message-store interface and return `ErrUnsupported`.

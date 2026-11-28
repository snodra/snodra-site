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
tests only. They are not durable, and `Start` warns when one is active. The in-memory message store implements the
saga and external-call ports too, so a test can drive `store.Sagas()` and `store.ExternalCalls()` directly.

A saga is a state type and a definition; test it by registering the definition on an app with the two in-memory
stores, feeding events through the `default` processor and letting the deadline scheduler run (the level-4 clocks are
fixed), as the library's `saga_test.go` does. An idempotent adapter is tested like any command handler, calling it with
an `idempotency-key` header and the same in-memory store; `external_test.go` shows the record, replay and marker cases.
There is no exported saga fixture in Go: the test drives the public `HandleSaga` API and the app.

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
the list on the [event-store contract](/docs/library-authors/event-store-add-ons/#the-conformance-kit)) and the six
possible level-3 ids, one form per capability: `replay_from_earliest_redelivers_history` (or
`admin_without_replay_is_unsupported` without `replay`), `lag_counts_unacked` (or `lag_unknown_without_capability`),
`dead_letter_source_receives` when the store declares `native-dead-letter`, and `no_browser_without_capability`
always. The four positive `browse` checks are omitted as a kit difference, because the Go library has no event
browser; `CheckIDs()` lists the 15 possible ids (both forms of `replay` and `lag` included), and `EventStoreKit` is
what every check runs on.

`snodratest.MessageStore` runs 28 checks: the nine level-2 outbox and processed-event checks, the eight level-3
processor checks (`delete_markers_removes_only_the_range`, `dead_letters_sequence_per_key`,
`dead_letter_parked_inside_rolled_back_transaction_is_kept`, `dead_letter_deleted_in_a_transaction_goes_with_it`,
`control_lock_is_exclusive_until_lease_expires`, `pause_state_round_trips`, `replay_ranges_round_trip` and
`processor_control_write_inside_rolled_back_transaction_is_kept`) and the eleven level-4 store checks
(`external_call_idempotency_returns_first_result`, `saga_ports_round_trip`,
`two_transactions_starting_one_saga_key_leave_one_live_saga`,
`two_transactions_updating_one_saga_version_commit_once`,
`saga_dispatch_store_refuses_an_event_the_outbox_would_refuse`,
`due_deadline_is_claimed_once_until_its_lease_passes`, `an_empty_deadline_correlation_id_reads_as_absent`,
`two_schedulers_claim_each_due_deadline_once`, `dispatch_hands_out_each_saga_in_seq_order`,
`two_relays_never_hold_one_saga_lease` and `concurrent_notice_claims_return_each_notice_once`). `StoreCheckIDs()`
lists them in the Rust kit's order.
Each check is a subtest named exactly as the Rust kit names it, and every check is exported, so a failing one can be run
by itself:

```go
// One level-3 check, on its own: the reset lock, the pause, the replay ranges, or the markers.
func TestReplayRanges(t *testing.T) {
	snodratest.ReplayRangesRoundTrip(t, newMyMessageStore(t))
}
```

The event-store kit always runs its level-3 checks and the message-store kit all 28; a level-2-only entry point is a
follow-up.

`snodratest` has no Docker and no store client. The add-on's own test provides the store and the infrastructure; the
kit only proves the contract. For a service's own tests, the in-memory message store implements the dead-letter and
processor-control ports too, so a test can drive `DeadLetters()` and `Control()` directly; the in-memory event store
declares `replay` and `lag` and **not** `native-dead-letter` (like the reference in-memory stores), so the
`event-store` dead-letter mode needs a durable event store, or a test store that declares the capability.

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

The runner proves level 1 only; levels 2 and 3 are proved by the add-on kits above and by the library's own tests of
the outbox, the relay and the consumer. The checks and what each asserts are listed in
[Feature levels](/docs/library-authors/feature-levels/) and in
[Conformance](/docs/library-authors/conformance/).

## Levels 3 and 4

Level 3 is proved by the kits above and by the library's own tests of the status, the control plane, the reset state
machine and the three dead-letter modes; the runner still proves level 1 only. The message-store kit carries all 28
checks, so `snodratest.MessageStore` runs the nine level-2, eight level-3 and eleven level-4 checks on the memory store
and both official stores in `v0.7.0`; `StoreCheckIDs()` lists them in the Rust kit's order. Level 4 is also proved by
the library's own saga tests (stage 2, the dispatch relay, the notice and deadlines) and external-call tests (the
record lifecycle, takeover and the two markers), which run on the in-memory store.

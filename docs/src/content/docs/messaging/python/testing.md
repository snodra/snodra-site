---
title: "Testing"
---

## Testing your handlers

A handler is a plain async function, `async def handle(cmd: C) -> R` (an event handler is
`async def handle(e: E) -> None`), so a service tests it as one: call the function with a message and assert on the
result or exception. Keep the function apart from the registration (a named function passed to `@app.command_handler`
or `@app.event_handler`) so that a test can call it directly with `pytest`.

An event handler is tested the same way. A test that wants the outbox and the markers can use the in-memory stores:
`snodra.MemoryStore()` and `snodra.MemoryEventStore()` are complete stores with no infrastructure, for tests only. They
are not durable, and `start` warns when one is active. `MemoryStore` implements the saga and external-call ports too,
so a test can drive `store.sagas` and `store.external` directly.

A saga is a class with decorated handlers; test it by registering it on an app with the two in-memory stores, feeding
events through the `default` processor and letting the deadline scheduler run (the level-4 clocks are fixed), as
`tests/test_saga_runtime.py` does. An idempotent adapter is tested like any command handler, with an
`idempotency-key` header and the same in-memory store; `tests/test_external.py` shows the record, replay, takeover and
marker cases. There is no exported saga fixture in Python: the test drives the public `@app.saga` API and the app.

To test the wiring against a real hub, run the hub image (`snodra/snodra-server`, see the
[Hub quick start](/docs/server/quickstart/)) and point the service at it with `SNODRA_SERVER_ADDRESS`.

## The library's own tests

The library's unit tests need no Docker and run against an in-process scripted hub, in the core package and in
`packages/snodra-messaging-observability/`:

```sh
uv run pytest -q
```

The add-on packages are separate packages, each with its own tests:

```sh
uv run pytest packages/snodra-messaging-kafka         # a Kafka broker
uv run pytest packages/snodra-messaging-rabbitmq      # RabbitMQ with the stream and management plugins
uv run pytest packages/snodra-messaging-mongo         # a MongoDB replica set
uv run pytest packages/snodra-messaging-sql           # PostgreSQL and MySQL
```

Their integration tests use Testcontainers; without a working Docker they skip and the unit tests still run. The SQL
package runs its suite on both PostgreSQL and MySQL.

## The add-on kits

`snodra.testing` is the conformance kit for add-ons; it imports only the standard library and the core, so an add-on
depends on the core, never the reverse. An add-on runs the kit from its own test:

```python
from snodra.testing import run_event_store_conformance, run_store_conformance

async def test_my_event_store():
    await run_event_store_conformance("conformance.events", lambda: make_store(), marker_store)

async def test_my_event_store_at_level_3():
    await run_event_store_conformance(
        "conformance.events", lambda: make_store(), marker_store, level=3
    )

async def test_my_message_store():
    await run_store_conformance(lambda: make_message_store())

async def test_my_message_store_at_level_3():
    # run_store_l3_conformance(lambda: make_message_store()) is the same run.
    await run_store_conformance(lambda: make_message_store(), level=3)

async def test_my_message_store_at_level_4():
    # run_store_l4_conformance(lambda: make_message_store()) is the same run.
    await run_store_conformance(lambda: make_message_store(), level=4)
```

`run_event_store_conformance(source, open_store, store, *, level=2)` runs the nine level-2 event-store checks
(`headers_round_trip`, `same_key_arrives_in_publish_order`, `every_processor_gets_every_event`,
`instances_share_a_processor`, and the rest of the list on the
[event-store contract](/docs/library-authors/event-store-add-ons/#the-conformance-kit)); `open_store` is called once
per service instance, and `store` is a message store for the at-least-once check's markers. `level=3` runs those nine
checks and the six possible level-3 ids, one form per capability: `replay_from_earliest_redelivers_history`
(or `admin_without_replay_is_unsupported` without `replay`), `lag_counts_unacked` (or `lag_unknown_without_capability`),
`dead_letter_source_receives` when the store declares `native-dead-letter`, and `no_browser_without_capability`
always. `EVENT_STORE_CHECKS` holds the nine, `EVENT_STORE_L3_CHECKS` the six possible ids, and
`run_event_store_l3_conformance(source, open_store, store)` is the same run as `level=3`.
`run_store_conformance(open_store, *, level=2)` runs the nine level-2
outbox and processed-event checks; `level=3` runs those nine and the eight level-3 dead-letter and processor-control
checks (`delete_markers_removes_only_the_range`, `dead_letters_sequence_per_key`,
`dead_letter_parked_inside_rolled_back_transaction_is_kept`, `dead_letter_deleted_in_a_transaction_goes_with_it`,
`control_lock_is_exclusive_until_lease_expires`, `pause_state_round_trips`, `replay_ranges_round_trip` and
`processor_control_write_inside_rolled_back_transaction_is_kept`), 17 in all; `level=4` runs all 28, adding the eleven
level-4 store checks: `external_call_idempotency_returns_first_result`, `saga_ports_round_trip`,
`two_transactions_starting_one_saga_key_leave_one_live_saga`,
`two_transactions_updating_one_saga_version_commit_once`,
`saga_dispatch_store_refuses_an_event_the_outbox_would_refuse`,
`due_deadline_is_claimed_once_until_its_lease_passes`, `an_empty_deadline_correlation_id_reads_as_absent`,
`two_schedulers_claim_each_due_deadline_once`, `dispatch_hands_out_each_saga_in_seq_order`,
`two_relays_never_hold_one_saga_lease` and `concurrent_notice_claims_return_each_notice_once`. The default `level=2`
preserves the published entry point; `run_store_l3_conformance(open_store)` and `run_store_l4_conformance(open_store)`
are the named entry points for the `level=3` and `level=4` runs, `MESSAGE_STORE_CHECKS` lists the nine,
`MESSAGE_STORE_L3_CHECKS` the eight and
`MESSAGE_STORE_L4_CHECKS` the eleven (what each asserts is on the
[store contract](/docs/library-authors/message-store-add-ons/#the-conformance-kit)). Each check is an async function
named exactly as the Rust kit names it, and every check is exported, so a failing one can be run by itself (a
`MessageStore` for the store checks, an `EventStoreKit` for the event-store checks):

```python
from snodra.testing import (
    dead_letters_sequence_per_key,
    pause_state_round_trips,
    replay_ranges_round_trip,
)

async def test_control_state():
    store = make_message_store()
    await replay_ranges_round_trip(store)   # the reset's ranges
    await pause_state_round_trips(store)    # the persisted pause
    await dead_letters_sequence_per_key(store)
```

`snodra.testing` has no Docker and no store client. The add-on's own test provides the store and the infrastructure;
the kit only proves the contract. For a service's own tests, `MemoryStore` implements the dead-letter and
processor-control ports, so a test can drive `store.dead_letters` and `store.control` directly; `MemoryEventStore`
declares `replay` and `lag` and **not** `native-dead-letter` (like the reference in-memory stores), so the `event-store`
dead-letter mode needs a durable event store, or a test store that declares the capability.

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

Level 3 is proved by both kits above: `run_event_store_conformance(..., level=3)` runs the nine level-2 checks and the
six possible level-3 ids, one form per capability (`EVENT_STORE_L3_CHECKS`), with `run_event_store_l3_conformance` as
the named entry point; `run_store_conformance(..., level=3)` runs the nine level-2 store checks and the eight level-3
dead-letter and processor-control checks (`MESSAGE_STORE_L3_CHECKS`), with `run_store_l3_conformance` as the named entry
point. The
library's own tests prove the status, the control plane, the reset state machine and the three dead-letter modes; the
runner still proves level 1 only. Level 4 is proved by the eleven level-4 store checks:
`run_store_conformance(..., level=4)` and `run_store_l4_conformance` run all 28
(`MESSAGE_STORE_CHECKS`, `MESSAGE_STORE_L3_CHECKS` and `MESSAGE_STORE_L4_CHECKS`), on the memory store and both
official stores in 0.8.0. The library's own tests add the saga runtime (stage 2, the dispatch relay, the notice and
deadlines) and the idempotent adapter (the record lifecycle, takeover and the two markers), on the in-memory store.

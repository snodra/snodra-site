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
are not durable, and `start` warns when one is active.

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
```

`run_event_store_conformance(source, open_store, store, *, level=2)` runs the nine level-2 event-store checks
(`headers_round_trip`, `same_key_arrives_in_publish_order`, `every_processor_gets_every_event`,
`instances_share_a_processor`, and the rest of the list on the
[event-store contract](/docs/library-authors/event-store-add-ons/#the-conformance-kit)); `open_store` is called once
per service instance, and `store` is a message store for the at-least-once check's markers. `level=3` runs those nine
checks and the six level-3 capability checks in the form the store declares: `replay_from_earliest_redelivers_history`
(or `admin_without_replay_is_unsupported` without `replay`), `lag_counts_unacked` (or `lag_unknown_without_capability`),
`dead_letter_source_receives` when the store declares `native-dead-letter`, and `no_browser_without_capability`.
`run_store_conformance(open_store, *, level=2)` runs the nine level-2 outbox and processed-event checks, or with
`level=3` the 17: those nine and the eight level-3 dead-letter and processor-control checks
(`delete_markers_removes_only_the_range`, `dead_letters_sequence_per_key`,
`dead_letter_parked_inside_rolled_back_transaction_is_kept`, `dead_letter_deleted_in_a_transaction_goes_with_it`,
`control_lock_is_exclusive_until_lease_expires`, `pause_state_round_trips`, `replay_ranges_round_trip` and
`processor_control_write_inside_rolled_back_transaction_is_kept`). The default `level=2` preserves the published entry
point; `run_store_l3_conformance(open_store)` is the same run as a named entry point, and `MESSAGE_STORE_L3_CHECKS`
lists the eight on their own (what each asserts is on the
[store contract](/docs/library-authors/message-store-add-ons/#the-conformance-kit)). Each check is an async function
named exactly as the Rust kit names it, and every check is exported, so a failing one can be run by itself (a
`MessageStore` for the store checks, an `EventStoreKit` for the event-store checks).

`snodra.testing` has no Docker and no store client. The add-on's own test provides the store and the infrastructure;
the kit only proves the contract.

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

The level-3 kits exist: `run_event_store_conformance(..., level=3)` runs the nine level-2 checks and the six level-3
capability checks, and `run_event_store_l3_conformance` is the same run as a named entry point;
`run_store_conformance(..., level=3)` runs the nine level-2 store checks and the eight level-3 dead-letter and
processor-control checks, with `run_store_l3_conformance` as the named entry point and `MESSAGE_STORE_L3_CHECKS` listing
the eight. The library's level-3 work is in progress; the level-4 saga and external-call kits are not there yet.

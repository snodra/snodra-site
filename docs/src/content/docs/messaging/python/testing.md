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
from snodra.testing import EventStoreKit, run_event_store_conformance, run_store_conformance

async def test_my_event_store():
    kit = EventStoreKit("conformance.events", lambda: make_store(), marker_store)
    await run_event_store_conformance(kit)

async def test_my_message_store():
    await run_store_conformance(lambda: make_message_store())
```

`run_event_store_conformance` (or `EventStoreKit`) runs the nine level-2 event-store checks (`headers_round_trip`,
`same_key_arrives_in_publish_order`, `every_processor_gets_every_event`, `instances_share_a_processor`, and the rest of
the list on the [event-store contract](/docs/library-authors/event-store-add-ons/#the-conformance-kit));
`run_store_conformance` runs the nine outbox and processed-event checks. Each check is an async function named exactly as
the Rust kit names it, and every check is exported, so a failing one can be run by itself. The capability checks
(replay, lag, dead letters and browse) and the processor checks come with level 3.

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

The Python library has no processor status, processor control, dead letters or sagas yet, so there are no level-3 or
level-4 kits to run for it. The ports exist in the message-store interface and raise `MessageStoreUnsupported`.

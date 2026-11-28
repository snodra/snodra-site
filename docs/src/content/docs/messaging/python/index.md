---
title: "snodra-messaging-python"
---

The official Python client library of the Snodra messaging suite. An asyncio service registers handlers for commands,
queries, streaming queries, subscription queries and events, defines sagas, and sends messages to other services,
through a Snodra hub: the library keeps the hub streams, permits, retries, timeouts, the outbox, the relay, the event
consumers and the saga runtime, and you write async functions.

```sh
pip install snodra-messaging==0.8.0
```

**Status: pre-1.0, feature level 4 (0.8.0).** The library implements levels 1 to 4 of the protocol: it passes all 33
checks of the [conformance runner](/docs/tools/conformance-runner/) through `examples/conformance-service`, the
event-store and message-store kits through its add-on packages (including the eleven level-4 store checks and all 28
message-store checks), and the level-4 saga and external-call rules in its own tests. The current release is 0.8.0, for
the core, `snodra-messaging-observability` and every
add-on package; the six distributions are on
[PyPI](https://pypi.org/project/snodra-messaging/) and the GitHub release carries 12 assets. All are pre-1.0, so the API
may still change between minor versions. It needs Python 3.12 or later.

## What it gives you

- Typed handlers: `@app.command_handler`, `@app.query_handler`, `@app.stream_handler`, `app.subscription_handler` and
  `@app.event_handler`, with guards (`authenticated()`, `role()`, `caller_matches()`).
- Sending: `send` and `query`, with per-call timeout, routing key, priority, headers and an opt-in retry policy.
- Every query mode: point, scatter-gather (`gather`), streaming (`stream`) and subscription (`subscribe`); streams and
  subscriptions are async context managers and iterables (`async with`, `async for`).
- Events: `app.publish` appends the event to the service's outbox in the transaction bound to the current context, and
  the relay in every instance publishes it to the event store, at least once. `key` gives the event its order key.
- Event handlers: `@app.event_handler` runs in the `default` processor or in a named one (`processor=`), with the
  processed-event marker and the handler's writes in one transaction, so a redelivery is skipped.
- Sagas: `@app.saga` registers a class with `@saga_start`, `@saga_event`, `@saga_deadline` and
  `@saga_command_failed` handlers. Sagas run in the `default` processor after the event handlers (stage 2), with
  associations, start keys, an optimistic state version, parked failures and deadlines. A relay in every instance
  sends each saga's commands and events after its transaction committed, in `seq` order under a lease; a command
  carries `idempotency-key` and `saga-id`, the recording message's correlation and trace, and no caller identity.
- Idempotent external calls: `@app.idempotent_command_handler` records each call under the `idempotency-key` header in
  `external_calls`, so a command the saga relay sends twice reaches the external system once. `snodra.Retryable` and
  `snodra.UnknownOutcome` write the two reserved markers the relay reads.
- Processor status and control: every started processor reports its state, segments, counters, last error and
  dead-letter count to the hub; the hub pauses and resumes it persistently, resets it to earliest, latest, a timestamp
  or explicit positions (a leased operation, with `@app.reset_handler` handlers), and lists, retries and discards its
  dead letters. `replay=False` keeps a handler out of a replay, and every control runs off the hub read loop.
- Dead letters: `Settings.dead_letter_mode` (`SNODRA_EVENTS_DEAD_LETTER_MODE`) parks a record that exhausts its
  attempts in `collection` (the message store's dead letters), publishes it to the `<source>.dlt` source with the six
  `snodra-dlt-*` headers in `event-store`, or logs it and moves on in `log`;
  `Settings.dead_letter_retention` (`SNODRA_EVENTS_DEAD_LETTER_RETENTION_MS`, 30 days by default) is how long a
  collected letter is kept.
- Stores: one event store and one message store, each a separate package: Kafka or RabbitMQ Streams for events; MongoDB
  or SQL (PostgreSQL, MySQL) for the outbox, the markers, the dead letters, the processor control, the external calls
  and the saga records. In-memory stores (`MemoryStore`, `MemoryEventStore`) are there for tests and local runs.
- The hub connection: registration, heartbeats, reconnect with backoff, flow control, timeouts, several hubs and an
  ordered shutdown.
- Static token, OAuth2 JWT (client credentials) and mutual TLS credentials, with rotation.
- Caller identity from the forwarded token, verified against the issuer's keys (`JWKS`); guards need a JWKS.
- Commands and queries of the service's own types answered in-process, without the hub, unless
  `always_route_through_hub` is on.
- Telemetry behind an interface, with an OpenTelemetry implementation in the separate
  `snodra-messaging-observability` package and the metric names and labels of the Kotlin, Rust and Go libraries.
- Conformance kits for add-ons, in `snodra.testing`: an add-on depends on the core, never the reverse.

## Level 4

The library is at [feature level 4](/docs/library-authors/feature-levels/): levels 1 to 3, plus sagas with
start/event/deadline/`SagaCommandFailed` handlers, the dispatch relay and its leases, and idempotent external calls
with the retryable and unknown-outcome markers. The saga and external-call store ports are implemented by the memory
store and both official message stores, which pass the eleven level-4 store checks; `run_store_conformance(...,
level=4)` runs all 28 checks ([Testing](/docs/messaging/python/testing/#the-add-on-kits)). Python and Go now match
Kotlin and Rust at level 4.

The Python library has no event browser, so its event-store add-ons declare no `browse` capability; its conformance
kit runs the browser check as `no_browser_without_capability`. Its saga and external-call implementation has the limits
listed in [API](/docs/messaging/python/api/#limits-and-differences): an adapter key is the `idempotency-key` header
only, and a panic in an adapter is settled as an unknown outcome.

## Add-ons

| Add-on | Package |
|---|---|
| Kafka event store | `snodra-messaging-kafka` (`pip install snodra-messaging-kafka==0.8.0`) |
| RabbitMQ Streams event store | `snodra-messaging-rabbitmq` (`pip install snodra-messaging-rabbitmq==0.8.0`) |
| MongoDB message store | `snodra-messaging-mongo` (`pip install snodra-messaging-mongo==0.8.0`) |
| SQL message store (PostgreSQL, MySQL) | `snodra-messaging-sql` (`pip install snodra-messaging-sql==0.8.0`) |

A service needs one event store and one message store, passed to `snodra.App` with `event_store=` and `store=`. The
[add-ons pages](/docs/add-ons/) describe the artifacts, the settings, the guarantees and the capabilities of each.

## Pages

- [Quick start](/docs/messaging/python/quickstart/): a service in one file, then an event, then a saga and an external
  call.
- [Configuration](/docs/messaging/python/configuration/): the `SNODRA_*` variables of the core and of every add-on, the
  `Settings` field that sets each, and every hub credential.
- [API](/docs/messaging/python/api/): handlers, sending, the four query modes, events, stores, processors, processor
  status and control, reset and replay, dead letters, sagas and deadlines, idempotent external calls, errors, identity,
  lifecycle and telemetry.
- [Testing](/docs/messaging/python/testing/): testing handlers and sagas, the `snodra.testing` kits, and running the
  conformance runner against the library's own service.
- [Kafka event store](/docs/add-ons/kafka-event-store/),
  [RabbitMQ Streams event store](/docs/add-ons/rabbitmq-streams-event-store/),
  [MongoDB message store](/docs/add-ons/mongodb-message-store/) and
  [SQL message store](/docs/add-ons/sql-message-store/): the add-ons.

The library's source, its `SPEC-GAPS.md` (where each specification rule the library had to decide comes from; the
library follows the Kotlin library) and its releases are in the
[repository](https://github.com/snodra/snodra-messaging-python).

---
title: "snodra-messaging-go"
---

The official Go client library of the Snodra messaging suite. A service registers handlers for commands, queries,
streaming queries, subscription queries and events, and sends messages to other services, through a Snodra hub: the
library keeps the hub streams, permits, retries, timeouts, the outbox, the relay and the event consumers, and you write
functions.

```sh
go get github.com/snodra/snodra-messaging-go@v0.6.0
```

**Status: pre-1.0, feature level 3 (`v0.6.0`).** The library implements levels 1 to 3 of the protocol: it passes all 33
checks of the [conformance runner](/docs/tools/conformance-runner/) through `examples/conformance-service`, and the
level-2 and level-3 event-store and message-store kits through its add-on modules. The current release is `v0.6.0`, with
each add-on module and `observability` tagged `v0.6.0` too; the versions are on the
[releases page](https://github.com/snodra/snodra-messaging-go/releases). All are pre-1.0, so the API may still change
between minor versions. It needs Go 1.26 or later.

## What it gives you

- Typed handlers: `HandleCommand`, `HandleQuery`, `HandleStream`, `HandleSubscription` and `HandleEvent`, with guards
  (`RequireAuthenticated`, `RequireRole`, `RequireCaller`).
- Sending: `Send` and `Query`, with per-call timeout, routing key, priority, headers and an opt-in retry policy.
- Every query mode: point, scatter-gather (`Gather`), streaming (`Stream`) and subscription (`Subscribe`); streams and
  subscription updates are `iter.Seq2[T, error]`.
- Events: `Publish` appends the event to the service's outbox in the transaction the context carries, and the relay in
  every instance publishes it to the event store, at least once. `Key` gives the event its order key.
- Event handlers: `HandleEvent` runs in the `default` processor or in a named one (`InProcessor`), with the
  processed-event marker and the handler's writes in one transaction, so a redelivery is skipped.
- Processor status and control: every started processor reports its state, segments, counters, last error and
  dead-letter count to the hub; the hub pauses and resumes it persistently, resets it to earliest, latest, a timestamp
  or explicit positions (a leased operation, with `HandleReset` handlers), and lists, retries and discards its dead
  letters. `DisallowReplay()` keeps a handler out of a replay, and every control runs off the hub read loop.
- Dead letters: a record that exhausts its attempts is parked according to `DeadLetterMode`
  (`SNODRA_DEAD_LETTER_MODE`): `collection` keeps it in the message store's dead letters, `event-store` publishes it to
  the `<source>.dlt` source with the six `snodra-dlt-*` headers, and `log` logs it and moves on.
- Stores: one event store and one message store, each a separate module: Kafka or RabbitMQ Streams for events; MongoDB
  or SQL (PostgreSQL, MySQL) for the outbox, the markers, the dead letters and the processor control. In-memory stores
  are there for tests and local runs.
- The hub connection: registration, heartbeats, reconnect with backoff, flow control, timeouts, several hubs and an
  ordered shutdown.
- Static token, OAuth2 JWT (client credentials) and mutual TLS credentials, with rotation.
- Caller identity from the forwarded token, verified against the issuer's keys (`JWKS`); guards need a JWKS.
- Commands and queries of the service's own types answered in-process, without the hub, unless
  `AlwaysRouteThroughHub` is on.
- Telemetry behind an interface, with an OpenTelemetry implementation in the separate `observability` module and the
  metric names and labels of the Kotlin and Rust libraries.
- A conformance kit for add-ons, `snodratest`, on the standard library only: an add-on depends on the core, never the
  reverse.

## Level 3

The library is at [feature level 3](/docs/library-authors/feature-levels/): commands and queries in every mode, events
through the outbox, at-least-once handlers and named processors, plus the processor status and control of level 3 —
pause and resume, the leased reset with reset handlers and replay, and the dead letters in their three modes. The
interfaces of the event store and the message store are frozen through this level, so a third-party add-on compiles
once.

Sagas (level 4) are not in the library yet. The Go library has no event browser, so its event-store add-ons declare no
`browse` capability and its conformance kit omits the four `browse`-capability checks
([Testing](/docs/messaging/go/testing/#the-add-on-kits)).

## Add-ons

| Add-on | Module |
|---|---|
| Kafka event store | `github.com/snodra/snodra-messaging-go/kafka` |
| RabbitMQ Streams event store | `github.com/snodra/snodra-messaging-go/rabbitmq` |
| MongoDB message store | `github.com/snodra/snodra-messaging-go/mongo` |
| SQL message store (PostgreSQL, MySQL) | `github.com/snodra/snodra-messaging-go/sql` |

A service needs one event store and one message store, passed with `WithEventStore` and `WithStore`. The
[add-ons pages](/docs/add-ons/) describe the artifacts, the settings, the guarantees and the capabilities of each.

## Pages

- [Quick start](/docs/messaging/go/quickstart/): a service in one file, then an event.
- [Configuration](/docs/messaging/go/configuration/): the `SNODRA_*` variables of the core and of every add-on, the
  option that sets each, and every hub credential.
- [API](/docs/messaging/go/api/): handlers, sending, the four query modes, events, stores, processors, processor
  status and control, reset and replay, dead letters, errors, identity, lifecycle and telemetry.
- [Testing](/docs/messaging/go/testing/): testing handlers, the `snodratest` kits, and running the conformance runner
  against the library's own service.
- [Kafka event store](/docs/add-ons/kafka-event-store/),
  [RabbitMQ Streams event store](/docs/add-ons/rabbitmq-streams-event-store/),
  [MongoDB message store](/docs/add-ons/mongodb-message-store/) and
  [SQL message store](/docs/add-ons/sql-message-store/): the add-ons.

The library's source, its `SPEC-GAPS.md` (where each specification rule the library had to decide comes from; the
library follows the Kotlin library) and its releases are in the
[repository](https://github.com/snodra/snodra-messaging-go).

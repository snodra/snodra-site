---
title: "snodra-messaging-go"
---

The official Go client library of the Snodra messaging suite. A service registers handlers for commands, queries,
streaming queries, subscription queries and events, and sends messages to other services, through a Snodra hub: the
library keeps the hub streams, permits, retries, timeouts, the outbox, the relay and the event consumers, and you write
functions.

```sh
go get github.com/snodra/snodra-messaging-go@latest
```

**Status: pre-1.0, feature level 2.** The library implements levels 1 and 2 of the protocol: it passes all 33 checks of
the [conformance runner](/docs/tools/conformance-runner/) through `examples/conformance-service`, and the level-2
event-store and message-store kits through its add-on modules. The versions are on the
[releases page](https://github.com/snodra/snodra-messaging-go/releases); all are pre-1.0, so the API may still change
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
- Stores: one event store and one message store, each a separate module: Kafka or RabbitMQ Streams for events; MongoDB
  or SQL (PostgreSQL, MySQL) for the outbox and the markers. In-memory stores are there for tests and local runs.
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

## Level 2

The library is at [feature level 2](/docs/library-authors/feature-levels/): commands and queries in every mode, plus
events through the outbox, at-least-once handlers and named processors. The interfaces of the event store and the
message store are frozen at this level, so a third-party add-on compiles once.

Level 3 — processor status and control (pause and resume, reset and replay) and dead letters — is in progress: the
APIs are implemented on `main` and are claimed with the level-3 release. Sagas (level 4) are not in the library yet. The
Go library has no event browser either, so its event-store add-ons declare no `browse` capability. The latest level-2
release logs and skips a record that exhausts its attempts; with the level-3 release the record becomes a dead letter,
in the `collection` mode by default ([Configuration](/docs/messaging/go/configuration/#dead-letters-level-3-in-progress)).

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
- [API](/docs/messaging/go/api/): handlers, sending, the four query modes, events, stores, processors, errors,
  identity, lifecycle and telemetry.
- [Testing](/docs/messaging/go/testing/): testing handlers, the `snodratest` kits, and running the conformance runner
  against the library's own service.
- [Kafka event store](/docs/add-ons/kafka-event-store/),
  [RabbitMQ Streams event store](/docs/add-ons/rabbitmq-streams-event-store/),
  [MongoDB message store](/docs/add-ons/mongodb-message-store/) and
  [SQL message store](/docs/add-ons/sql-message-store/): the add-ons.

The library's source, its `SPEC-GAPS.md` (where each specification rule the library had to decide comes from; the
library follows the Kotlin library) and its releases are in the
[repository](https://github.com/snodra/snodra-messaging-go).

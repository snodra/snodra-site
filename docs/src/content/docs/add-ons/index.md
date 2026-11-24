---
title: "Add-ons"
---

Events live in an **event store**; the reliability plumbing lives in a **message store**. Both are
add-ons: the core library ships neither, so you choose the infrastructure you already run.

| Add-on | Kind | Artifact or crate | What it holds |
|---|---|---|---|
| [Kafka event store](/docs/add-ons/kafka-event-store/) | event store | `snodra-messaging-kafka` | Events, in ordered partitions |
| [RabbitMQ Streams event store](/docs/add-ons/rabbitmq-streams-event-store/) | event store | `snodra-messaging-rabbitmq` | Events, in partitioned streams |
| [MongoDB message store](/docs/add-ons/mongodb-message-store/) | message store | `snodra-messaging-mongo` | Outbox, markers, dead letters, sagas, processor control |
| [SQL message store](/docs/add-ons/sql-message-store/) | message store | `snodra-messaging-jdbc` (Kotlin), `snodra-messaging-sqlx` (Rust) | The same, in PostgreSQL or MySQL tables |

## Two choices, one of each

A service needs one event store and one message store. The libraries refuse an ambiguous setup: if
two event-store add-ons are on the classpath, `snodra.messaging.event-store` must name the one that
runs; two message-store add-ons without `snodra.messaging.store.type` fail the startup naming both.
A store bean the application defines itself wins over every add-on.

```yaml
snodra:
  messaging:
    event-store: kafka            # kafka | rabbitmq-streams | memory
    store:
      type: mongo                 # mongo | jdbc | memory
```

The Rust library has no classpath: you pass the store to the builder (`.event_store(...)`,
`.store(...)`), so the choice is in code.

## In-memory stores

Both libraries ship in-memory stores for tests and local runs. They are not durable, keep everything
until the process ends, and are never a fallback for a missing store. The libraries warn at startup
when one is active. See [Testing](/docs/operations/testing/).

## What the stores do not do

The add-ons do not create your infrastructure. Kafka topics, RabbitMQ super streams, databases and
credentials are yours. The event store keeps events only as long as its own retention allows; the
message store keeps the outbox and markers, not your domain state.

## Choosing

| If you… | Use |
|---|---|
| already run Kafka | [Kafka event store](/docs/add-ons/kafka-event-store/) |
| already run RabbitMQ 3.13+ with streams | [RabbitMQ Streams event store](/docs/add-ons/rabbitmq-streams-event-store/) |
| already run MongoDB (a replica set) | [MongoDB message store](/docs/add-ons/mongodb-message-store/) |
| already run PostgreSQL 13+ or MySQL 8.0.17+ | [SQL message store](/docs/add-ons/sql-message-store/) |
| want no infrastructure at all | the in-memory stores, for tests only |

The guarantees that span both stores are in [Consistency](/docs/concepts/consistency/). The wiring
and exact layout are in [the messaging model](/docs/messaging/).

If you write an add-on of your own, for an official library or a new one, follow the contracts in
[Event-store add-ons](/docs/library-authors/event-store-add-ons/) and
[Message-store add-ons](/docs/library-authors/message-store-add-ons/): the operations, the wire rules and the
conformance kit every add-on passes.

---
title: "Kafka event store"
---

The event store on Apache Kafka. Use it when Kafka is already your event backbone: it gives ordered,
partitioned events with replay, lag and a native dead-letter topic, and it is the layout the Kotlin
and Rust libraries share.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-kafka:0.6.1` |
| Rust | `snodra-messaging-kafka = "0.8"` |

The Kotlin module depends on the core starter; the Rust crate is passed to the builder with
`.event_store(...)`.

## Configuration

Kotlin, under `snodra.messaging.kafka.*`:

| Key | Default | Meaning |
|---|---|---|
| `bootstrap-servers` | `broker:19092` | Kafka bootstrap servers |
| `client-properties` | none | Extra producer, consumer and admin properties, for example `client-properties[security.protocol]=SASL_SSL`; never logged |
| `admin-timeout` | `10s` | The most one admin call, commit or offset read waits |
| `status-refresh` | `1s` | How often a subscription refreshes the end offsets it counts lag against |
| `max-poll-records` | `100` | Records one subscription poll takes at most |

Choose the store with `snodra.messaging.event-store=kafka` when another event store is on the
classpath too. The source topic and the dead-letter mode are core settings; see
[the messaging model](/docs/messaging/).

Rust, from the environment:

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_KAFKA_BOOTSTRAP` | `kafka:19092` | The bootstrap servers |
| `SNODRA_KAFKA_PROPERTY_<NAME>` | none | One librdkafka property for every client; `_` for `.` and `__` for `_` |

TLS needs the crate's `ssl` feature. Without it, a configuration that asks for TLS is refused when
the store or browser opens.

## Guarantees

- **Ordering per key.** The producer uses the Java client's default partitioner, so a key from a
  Kotlin and a Rust publisher lands on the same partition.
- **Idempotent publish.** The producer sets `enable.idempotence` and `acks=all`; a send takes at most
  40 seconds.
- **At-least-once consumption.** Offsets are committed after a record is acknowledged; a new group
  starts at the earliest offset. Processed-event markers suppress duplicates.
- **One consumer group per processor**, `<service>.<processor>`.
- **Native dead letters.** Mode `event-store` produces to `<source>.dlt`.
- **Replay, lag and browse.** The store declares all four capabilities; the event browser uses them.

The store never creates topics. A topic that cannot exist, a record that is too large, or a refused
authorization is given up at once; other failures are retried by the outbox relay.

## Read next

- The event record and the Kafka layout: [the messaging model](/docs/messaging/).
- Dead letters and processors: [Event processors reference](/docs/server/event-processors/).
- The other event store: [RabbitMQ Streams](/docs/add-ons/rabbitmq-streams-event-store/).
- What delivery does and does not promise: [Consistency](/docs/concepts/consistency/).

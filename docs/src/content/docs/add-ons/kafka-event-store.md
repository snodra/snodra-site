---
title: "Kafka event store"
---

The event store on Apache Kafka. Use it when Kafka is already your event backbone: it gives ordered,
partitioned events with replay, lag and a native dead-letter topic, and it is the layout the Kotlin,
Rust, Go and Python libraries share.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-kafka:0.6.1` |
| Rust | `snodra-messaging-kafka = "0.8"` |
| Go | `github.com/snodra/snodra-messaging-go/kafka` (`go get github.com/snodra/snodra-messaging-go/kafka@v0.6.0`) |
| Python | `snodra-messaging-kafka` (`pip install snodra-messaging-kafka==0.7.0`) |

The Kotlin module depends on the core starter; the Rust crate is passed to the builder with
`.event_store(...)`. The Go module is one add-on module, passed to `snodra.New` with `WithEventStore`
([Go events](/docs/messaging/go/api/#events)). The Python package is `snodra-messaging-kafka`, passed
to `snodra.App` with `event_store=` ([Python events](/docs/messaging/python/api/#events)).

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
classpath too, or pass it to `snodra.New` with `WithEventStore` in Go. The source topic and the
dead-letter mode are core settings; see [the messaging model](/docs/messaging/).

Rust, from the environment:

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_KAFKA_BOOTSTRAP` | `kafka:19092` | The bootstrap servers |
| `SNODRA_KAFKA_PROPERTY_<NAME>` | none | One librdkafka property for every client; `_` for `.` and `__` for `_` |

TLS needs the crate's `ssl` feature. Without it, a configuration that asks for TLS is refused when
the store or browser opens.

Go, from the environment and `kafka.Config`:

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_KAFKA_BOOTSTRAP` | `kafka:19092` | The bootstrap servers, `host:port` entries separated by commas |
| `Config.MaxPollRecords` | 100 | The most records one poll hands a subscription |
| `Config.StatusRefresh` | 1s | How often a subscription refreshes the end offsets and the committed offsets it counts lag from |
| `Config.AdminTimeout` | 10s | The most one admin call, commit or offset read waits |
| `Config.Options` | none | Extra franz-go options for every client: TLS, SASL, a logger. The store sets the group, topic, reset offset, group protocol, partitioner and commit behavior itself |

`kafka.FromEnv()` reads `SNODRA_KAFKA_BOOTSTRAP` and leaves the other fields at their defaults; set
them on the returned `Config`. There are no librdkafka properties in the Go module: a connection
setting is a franz-go option in `Config.Options`. The module is
`github.com/snodra/snodra-messaging-go/kafka`; the full Go settings are in
[Go configuration](/docs/messaging/go/configuration/#kafka-kafkafromenv).

Python, from the environment and `KafkaConfig`:

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_KAFKA_BOOTSTRAP` | `kafka:19092` | The bootstrap servers, `host:port` entries separated by commas |
| `KafkaConfig.client_id` | `snodra-messaging` | The client identifier sent with broker requests |
| `KafkaConfig.request_timeout_ms` | 30 000 | The longest one broker request waits |
| `KafkaConfig.session_timeout_ms` | 10 000 | How long a crashed instance stays a group member |
| `KafkaConfig.max_poll_records` | 100 | The most records one poll hands a subscription |
| `KafkaConfig.status_refresh` | 1.0s | How often a subscription refreshes the end offsets it counts lag from |
| `KafkaConfig.admin_timeout` | 10.0s | The most one admin call, commit or offset read waits |

`KafkaConfig.from_env()` reads `SNODRA_KAFKA_BOOTSTRAP` and leaves the other fields at their defaults; set
them on the returned `KafkaConfig`. Pass the store to `snodra.App` with `event_store=KafkaEventStore(config)`.
The package is `snodra-messaging-kafka`; the full Python settings are in
[Python configuration](/docs/messaging/python/configuration/#kafka-kafkaconfigfrom_env).

## Guarantees

- **Ordering per key.** The producer uses the Java client's default partitioner, so a key from a
  Kotlin, Rust, Go or Python publisher lands on the same partition. (The Go and Python producers use murmur2 of the
  key's bytes, seed `0x9747b28c`, masked positive and taken modulo the partitions.)
- **Idempotent publish.** The producer sets `enable.idempotence` and `acks=all`; a send takes at
  most 40 seconds. The Go add-on sets `acks=all` and a 30-second delivery timeout; franz-go's
  idempotent write is on unless `Config.Options` turns it off.
- **At-least-once consumption.** Offsets are committed after a record is acknowledged; a new group
  starts at the earliest offset. Processed-event markers suppress duplicates.
- **One consumer group per processor**, `<service>.<processor>`.
- **Native dead letters.** Mode `event-store` produces to `<source>.dlt`. The store declares the
  capability, and the Go (0.6.0) and Python (0.7.0) libraries use it in the `event-store` mode.
- **Replay, lag and browse.** The Kotlin and Rust stores declare all four capabilities. The Go and
  Python add-ons declare `replay`, `lag` and `native-dead-letter` and no `browse`, because neither
  library has an event browser.
- **Group protocol.** The Go and Python add-ons join the classic group protocol with the `range` assignor, and
  a group's committed offset is the next one to read, so the members of every official library meet
  in one group.

The store never creates topics. A topic that cannot exist, a record that is too large, or a refused
authorization is given up at once; other failures are retried by the outbox relay.

## Capabilities

| Capability | Kotlin | Rust | Go | Python |
|---|---|---|---|---|
| `replay` | yes | yes | yes | yes |
| `lag` | yes | yes | yes | yes |
| `native-dead-letter` | yes | yes | yes | yes |
| `browse` | yes | yes | no: the Go library has no event browser | no: the Python library has no event browser |

## Read next

- The event record and the Kafka layout: [the messaging model](/docs/messaging/).
- Dead letters and processors: [Event processors reference](/docs/server/event-processors/).
- The other event store: [RabbitMQ Streams](/docs/add-ons/rabbitmq-streams-event-store/).
- What delivery does and does not promise: [Consistency](/docs/concepts/consistency/).
- The Go settings and API: [Go configuration](/docs/messaging/go/configuration/#kafka-kafkafromenv) and
  [Go events](/docs/messaging/go/api/#events).
- The Go add-on's own contract: [Event-store add-ons](/docs/library-authors/event-store-add-ons/).
- The Python settings and API: [Python configuration](/docs/messaging/python/configuration/#kafka-kafkaconfigfrom_env) and
  [Python events](/docs/messaging/python/api/#events).

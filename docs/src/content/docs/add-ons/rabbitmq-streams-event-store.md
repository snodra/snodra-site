---
title: "RabbitMQ Streams event store"
---

The event store on **RabbitMQ 3.13 or later with the stream plugin**. Use it when RabbitMQ is already
the broker you operate and you want events in partitioned streams without adding Kafka.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-rabbitmq:0.6.1` |
| Rust | `snodra-messaging-rabbitmq = "0.8"` |
| Go | `github.com/snodra/snodra-messaging-go/rabbitmq` (`go get github.com/snodra/snodra-messaging-go/rabbitmq@latest`) |

The Kotlin module pins the RabbitMQ Stream Java client version; a Spring Boot service that manages
that dependency must set `rabbit-stream-client.version` to the version the add-on needs, or the
startup fails naming it. The Go module is one add-on module, passed to `snodra.New` with
`WithEventStore` ([Go events](/docs/messaging/go/api/#events)). It speaks the stream protocol's
low-level commands itself so that it can set the `snodra-member` property on every consumer, and
uses the official Go client for AMQP 1.0 encoding.

## Create the streams first

The library never creates them. The source is a super stream, and the dead-letter stream is a plain
stream:

```sh
rabbitmq-streams add_super_stream snodra.events --partitions 6
rabbitmqadmin declare queue --name snodra.events.dlt --type stream --durable true
```

A missing super stream fails publishes (the relay retries) and subscriptions (they retry after a
backoff), naming the command above.

## Configuration

Kotlin, under `snodra.messaging.rabbitmq.*`; the Rust crate reads the same settings as
`SNODRA_RABBITMQ_*`:

| Key | Default | Meaning |
|---|---|---|
| `hosts` | `rabbitmq` | Nodes to try first, `host` or `host:port`, comma-separated |
| `port` | `5552` (`5551` with TLS) | Port of a host given without one |
| `virtual-host` | `/` | Virtual host |
| `username` | `guest` | User |
| `password` / `password-file` | `guest` | Password, or a file holding it; the file wins and is never logged |
| `tls` | `false` | TLS to every node, with host name verification |
| `tls-ca-file` | none | PEM CA certificates; required with TLS |
| `load-balancer` | `false` | The hosts are a load balancer; keep trying until the needed node answers |
| `offset-store-messages` | `10000` | Store a position every so many acknowledgements |
| `offset-store-interval` | `5s` | Or this often, whichever comes first |
| `confirm-timeout` | `30s` | The longest a publish waits for the broker's confirm |
| `management.url` | none | The management API; declares `replay` and shows live subscriptions |
| `management.username` / `password` / `password-file` / `ca-file` | the stream user's | The management API's own login and CA |

Select it with `snodra.messaging.event-store=rabbitmq-streams` when Kafka is on the classpath too.
The source and dead-letter source are core settings.

Go, through `rabbitmq.FromEnv` and `rabbitmq.Config`:

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_RABBITMQ_HOSTS` | `rabbitmq` | Nodes to try first, `host` or `host:port`, comma-separated |
| `SNODRA_RABBITMQ_PORT` | `5552` (`5551` with TLS) | Port of a host given without one |
| `SNODRA_RABBITMQ_VIRTUAL_HOST` | `/` | Virtual host; empty reads as `/` |
| `SNODRA_RABBITMQ_USERNAME` / `SNODRA_RABBITMQ_PASSWORD` | `guest` | User and password; the password is never logged |
| `SNODRA_RABBITMQ_TLS` | `false` | TLS to every node, TLS 1.2 or later, verified against the system roots. A private CA is `Config.TLS`: there is no CA-file variable in Go |
| `SNODRA_RABBITMQ_MANAGEMENT_URL` | none | The management API's root (`http://rabbitmq:15672`, no credentials in it); declares `replay` |
| `Config.ManagementUsername` / `Config.ManagementPassword` | the stream user's | The management API's own login |
| `Config.ManagementTimeout` | 5s | The longest one management API request waits |
| `Config.ConfirmTimeout` | 30s | The longest a publish waits for the broker's confirm |
| `Config.RequestTimeout` | 10s | The longest one stream request waits |
| `Config.OffsetStoreMessages` / `Config.OffsetStoreInterval` | 10 000 / 5s | Store a position after so many acknowledgements, or this often, whichever comes first |

`rabbitmq.New` does not connect; `rabbitmq.Open` asks the configured management API once whether its
metrics collection is on, and drops `replay` when it is not. Without the management API, a reset is
`UNSUPPORTED`. The full Go settings are in
[Go configuration](/docs/messaging/go/configuration/#rabbitmq-streams-rabbitmqfromenv).

## Guarantees

- **Ordering per key.** Events go to a partition by key; a processor sees a key in publish order.
  The partition is the stream clients' hash routing: murmur3 x86_32 of the routing key's UTF-8
  bytes (the event's key, else its id), seed 104729, unsigned, modulo the partitions in the
  broker's order. A Kotlin, Rust or Go publisher of one key therefore writes to one partition.
- **Single active consumer.** A processor `<service>.<processor>` is a single active consumer on every
  partition, so the broker spreads partitions over instances. The Go consumer adds the
  `snodra-member` property (a random id per instance), as the wire rules require.
- **At-least-once.** Positions are stored periodically (10 000 events or 5 seconds); after a crash up
  to that much is delivered again, and markers skip it.
- **Dead letters.** `browse`, `lag` and `native-dead-letter` are always available in the Kotlin and
  Rust stores. The Go add-on declares `lag` and `native-dead-letter`; it has no event browser, so it
  declares no `browse`.
- **Replay only with the management API.** Without `management.url`, a reset is answered
  `UNSUPPORTED`. The Go add-on declares `replay` only when the management API is configured and its
  metrics collection is on.
- **No producer deduplication.** A republished event is a duplicate, which markers suppress.

Limits worth knowing: an event over the 1 MiB frame is refused; publishing is one confirm round trip
per event (about 1 700 events/s against a local broker, consuming about 6 700/s); losing a broker
node stalls the partitions it led until the broker's consumer-disconnect timeout passes.

## Capabilities

| Capability | Kotlin | Rust | Go |
|---|---|---|---|
| `replay` | with the management API | with the management API | with `SNODRA_RABBITMQ_MANAGEMENT_URL`, once `Open` found its metrics collection on |
| `lag` | yes | yes | yes |
| `native-dead-letter` | yes | yes | yes |
| `browse` | yes | yes | no: the Go library has no event browser |

## Read next

- The shared layout and full rules: [the messaging model](/docs/messaging/).
- The other event store: [Kafka](/docs/add-ons/kafka-event-store/).
- Processor control and replay: [Processor control](/docs/server/processor-control/).
- Delivery semantics: [Consistency](/docs/concepts/consistency/).
- The Go settings and API: [Go configuration](/docs/messaging/go/configuration/#rabbitmq-streams-rabbitmqfromenv)
  and [Go events](/docs/messaging/go/api/#events).
- The add-on contract: [Event-store add-ons](/docs/library-authors/event-store-add-ons/).

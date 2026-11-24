# RabbitMQ Streams event store

The event store on **RabbitMQ 3.13 or later with the stream plugin**. Use it when RabbitMQ is already
the broker you operate and you want events in partitioned streams without adding Kafka.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-rabbitmq:0.6.1` |
| Rust | `snodra-messaging-rabbitmq = "0.7"` |

The Kotlin module pins the RabbitMQ Stream Java client version; a Spring Boot service that manages
that dependency must set `rabbit-stream-client.version` to the version the add-on needs, or the
startup fails naming it.

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

## Guarantees

- **Ordering per key.** Events go to a partition by key; a processor sees a key in publish order.
- **Single active consumer.** A processor `<service>.<processor>` is a single active consumer on every
  partition, so the broker spreads partitions over instances.
- **At-least-once.** Positions are stored periodically (10 000 events or 5 seconds); after a crash up
  to that much is delivered again, and markers skip it.
- **Dead letters.** `browse`, `lag` and `native-dead-letter` are always available.
- **Replay only with the management API.** Without `management.url`, a reset is answered
  `UNSUPPORTED`.
- **No producer deduplication.** A republished event is a duplicate, which markers suppress.

Limits worth knowing: an event over the 1 MiB frame is refused; publishing is one confirm round trip
per event (about 1 700 events/s against a local broker, consuming about 6 700/s); losing a broker
node stalls the partitions it led until the broker's consumer-disconnect timeout passes.

## Read next

- The shared layout and full rules: [the messaging model](../messaging/index.md).
- The other event store: [Kafka](kafka-event-store.md).
- Processor control and replay: [Processor control](../server/processor-control.md).
- Delivery semantics: [Consistency](../concepts/consistency.md).

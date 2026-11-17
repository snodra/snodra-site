# From kraken

Snodra is the renamed `kraken` stack: the same design, the same message shapes and the same stored
data, with new names. This page is the engineer's map. It is a clean cut — there are no aliases — and
the server and every client must move together, because the gRPC package changed.

## Names

| Old | New |
|---|---|
| `kraken-hub` (the deployable) | `snodra-server` / **Snodra Server** |
| `kraken-messaging` | `snodra-messaging` |
| `kraken-messaging-rs` | `snodra-messaging-rs` |
| `kraken-event-browser` | `snodra-event-browser` |
| `kraken-conformance` | `snodra-conformance` |
| image `.../kraken-hub` | `snodra/snodra-server` |
| binary `/app/kraken-hub` | `/app/snodra-server` |

The private services and the umbrella keep their `kraken` names and packages. They change only what
they must to build against the new public coordinates.

## Coordinates and code

| Surface | Old | New |
|---|---|---|
| Maven group | `io.damoreira.kraken` | `com.damoreira.snodra` |
| Kotlin artifact | `kraken-messaging` | `snodra-messaging` (0.5.0) |
| Add-ons | `kraken-messaging-{kafka,rabbitmq,mongo,jdbc}` | `snodra-messaging-{kafka,rabbitmq,mongo,jdbc}` |
| Java packages | `io.damoreira.kraken.messaging.*` | `com.damoreira.snodra.messaging.*` |
| Generated proto classes | `io.damoreira.kraken.hub.v1` | `com.damoreira.snodra.server.v1` |
| Kotlin classes | `KrakenMessaging*`, `KrakenContainers`, `KrakenTestKafka` | `SnodraMessaging*`, `SnodraContainers`, `SnodraTestKafka` |
| Rust crates | `kraken-messaging-rs`, `-kafka`, `-mongo`, `-sqlx`, `-rabbitmq` | `snodra-messaging-rs` (0.6), `snodra-messaging-*` |
| Rust lib / types | `kraken_messaging`, `KrakenMessaging` | `snodra_messaging`, `SnodraMessaging` |

The Rust crates moved from a git dependency to crates.io: `cargo add snodra-messaging-rs@0.6`.
Nothing else in the API changed.

## Settings

Every `KRAKEN_*` variable is now `SNODRA_*`; the hub client's `KRAKEN_HUB_*` names became the
server's own `SNODRA_SERVER_*` names. The Spring prefix moved from `kraken.messaging.*` to
`snodra.messaging.*`.

| Old | New |
|---|---|
| `KRAKEN_SERVICE_NAME`, `KRAKEN_INSTANCE_ID` | `SNODRA_SERVICE_NAME`, `SNODRA_INSTANCE_ID` |
| `KRAKEN_HUB_ADDRESS`, `KRAKEN_HUB_ENABLED` | `SNODRA_SERVER_ADDRESS`, `SNODRA_SERVER_ENABLED` |
| `KRAKEN_HUB_TOKEN`, `KRAKEN_HUB_TOKEN_FILE` | `SNODRA_SERVER_TOKEN`, `SNODRA_SERVER_TOKEN_FILE` |
| `KRAKEN_HUB_TLS*`, `KRAKEN_HUB_OAUTH2_*` | `SNODRA_SERVER_TLS*`, `SNODRA_SERVER_OAUTH2_*` |
| `KRAKEN_EVENTS_*`, `KRAKEN_OUTBOX_*`, `KRAKEN_STORE_*` | `SNODRA_EVENTS_*`, `SNODRA_OUTBOX_*`, `SNODRA_STORE_*` |
| `KRAKEN_KAFKA_*`, `KRAKEN_RABBITMQ_*` | `SNODRA_KAFKA_*`, `SNODRA_RABBITMQ_*` |
| `KRAKEN_MONGODB_URI`, `KRAKEN_OTLP_ENDPOINT` | `SNODRA_MONGODB_URI`, `SNODRA_OTLP_ENDPOINT` |

The client version announced to the server is `snodra-messaging/<version>` or
`snodra-messaging-rs/<version>`; the default address is `static://snodra-server:7000`. The ACL file
default is `/etc/snodra-server/acl.toml`, the default server id is `snodra-server-<suffix>`, and the
JWT audience default is `snodra-server`.

## Metrics

Every instrument is `snodra_*`. `kraken_*` dashboards, alerts and recording rules must be renamed;
Prometheus has no alias. The families are:

- `snodra_outbox_*`, `snodra_events_*`, `snodra_processor_*`, `snodra_dead_letters`,
  `snodra_sagas_*`, `snodra_deadlines_*`, `snodra_external_calls_*` — the libraries.
- `snodra_hub_client_*` — the library's hub client.
- `snodra_hub_*` — the server.
- `snodra_event_browser_*` — the browser service.

## Wire

The message shapes and record layout are unchanged. The identity on the wire is not:

- the gRPC package is **`snodra.hub.v1`** (the health service is `snodra.hub.v1.Hub`);
- the reserved query types are `snodra.events.Search`, `.Get`, `.Sources`, `.Lag` and `.Tail`, with
  the ACL namespace `snodra.events.`;
- the mTLS SAN scheme is `snodra://service/<name>`;
- webhook headers are `X-Snodra-Webhook-Secret` and `X-Snodra-Signature`;
- dead-letter records carry `snodra-dlt-*` headers;
- `SagaCommandFailed` is `snodra.SagaCommandFailed`;
- a RabbitMQ Streams consumer is marked `snodra-member`.

A server and a client on different sides of that package do not talk. Treat the rename as one
coordinated window: upgrade the server and every service together.

## Data

The following are **kept as they are**, so existing data needs no migration:

- the event source topic `kraken.events` and its dead-letter topic `kraken.events.dlt`, including
  source-derived stream names such as `kraken.events-3`;
- MongoDB collections and document fields, and every stored value;
- consumer groups `<service>.<processor>`;
- dead-letter ids and markers that embed the topic string;
- the event record layout: headers, key, payload.

SQL is the exception: the tables were renamed from `kraken_*` to `snodra_*` (with the schema file
`V1__snodra.sql`). Rename the tables or migrate the data before switching a service, and move the
Flyway history location with them. Every column, index and stored value is otherwise unchanged.

## Order of work

1. Record the current metric names and export the dashboards.
2. Move the server image and every client to the new coordinates and settings in one window.
3. Rename the SQL tables if you use that store; MongoDB and the event store need nothing.
4. Update dashboards, alerts, ACL files, JWT audiences and policy documents.
5. Verify registration on every server and a command round trip.

See [Upgrades](../operations/upgrades.md) for the rolling procedure and
[Compatibility](compatibility.md) for what the protocol version promises.

# Installation

Snodra has three installable pieces: the server, the Kotlin library and the Rust library. A
service uses one library; the server runs separately and every service connects to it.

## Server

The published image contains the gRPC listener, the dashboard, the HTTP API and the event browser.

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT= \
  snodra/snodra-server:0.5.0
```

| Port | Purpose |
|---|---|
| `7000` | gRPC, where services connect |
| `7001` | HTTP: the dashboard at `/ui/`, the API at `/api/v1/` |

`SNODRA_SERVER_OTLP_ENDPOINT=` disables trace export for this run; the default points at
`http://otel-lgtm:4317`. Pin the tag you deploy. Replace `0.5.0` with another release when you
upgrade; `latest` exists, but a fixed tag keeps a restart reproducible.

Check it:

```sh
curl -s localhost:7001/api/v1/version
```

The image is distroless and has no shell. Its `HEALTHCHECK` runs `/app/snodra-server
--health-check`, which probes the gRPC health service and exits `0` when it is `SERVING`.

Next: [the server quick start](../server/quickstart.md) for health, the dashboard and a first
request, and [server settings](../server/configuration/server.md) for every environment variable.

## Kotlin

The starter is a Spring Boot library. Add the core artifact and one event store and one message
store add-on:

```kotlin
// build.gradle.kts
repositories {
    mavenCentral()
}

dependencies {
    implementation("com.damoreira.snodra:snodra-messaging:0.5.0")
    implementation("com.damoreira.snodra:snodra-messaging-kafka:0.5.0")   // or snodra-messaging-rabbitmq
    implementation("com.damoreira.snodra:snodra-messaging-mongo:0.5.0")   // or snodra-messaging-jdbc
    testImplementation("com.damoreira.snodra:snodra-messaging-test:0.5.0")
}
```

Every artifact is on Maven Central; no repository configuration beyond `mavenCentral()` is needed.

| Artifact | Use |
|---|---|
| `snodra-messaging` | The buses, handler annotations, hub client, outbox, sagas and auto-configuration |
| `snodra-messaging-api` | `@MessageType`, `Event`, `Command`, `Query`, `StreamingQuery`; no Spring, for a service's `*-api` module |
| `snodra-messaging-kafka` | Kafka event store |
| `snodra-messaging-rabbitmq` | RabbitMQ Streams event store |
| `snodra-messaging-mongo` | MongoDB message store |
| `snodra-messaging-jdbc` | SQL message store for PostgreSQL and MySQL |
| `snodra-messaging-test` | In-memory buses, a fake hub, Testcontainers fixtures and the saga fixture |

The starter targets Spring Boot 4 and Kotlin 2.4. A project that applies
`io.spring.dependency-management` must set the Kotlin version in its build script; see
[the Kotlin quick start](../messaging/kotlin/quickstart.md).

Next: [the Kotlin quick start](../messaging/kotlin/quickstart.md), then
[configuration](../messaging/kotlin/configuration.md) and [add-ons](../add-ons/index.md).

## Rust

The crate and its add-ons come from crates.io:

```sh
cargo add snodra-messaging-rs@0.6
cargo add snodra-messaging-kafka@0.6        # or snodra-messaging-rabbitmq
cargo add snodra-messaging-mongo@0.6        # or snodra-messaging-sqlx with a database feature
```

| Crate | Use |
|---|---|
| `snodra-messaging-rs` | The hub client, events, processors, sagas and identity |
| `snodra-messaging-kafka` | Kafka event store, and partner topics as external sources |
| `snodra-messaging-rabbitmq` | RabbitMQ Streams event store |
| `snodra-messaging-mongo` | MongoDB message store |
| `snodra-messaging-sqlx` | SQL message store for PostgreSQL and MySQL (`postgres` or `mysql` feature) |

The SQL crate takes its database from its features:

```toml
snodra-messaging-sqlx = { version = "0.6", default-features = false, features = ["postgres"] }
```

For tests, enable the library's `testing` feature in dev-dependencies:

```toml
[dev-dependencies]
snodra-messaging-rs = { version = "0.6", features = ["testing"] }
```

Next: [the Rust quick start](../messaging/rust/quickstart.md), then
[configuration](../messaging/rust/configuration.md) and [add-ons](../add-ons/index.md).

## After installation

[Your first service](first-service.md) walks through the shortest path from a running server to a
registered handler. If you are replacing an existing deployment, read
[Migration](../migration/from-kraken.md) before you change coordinates.

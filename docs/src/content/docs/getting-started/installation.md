---
title: "Installation"
---

Snodra has four installable pieces: the server, the Kotlin library, the Rust library and the Go library. A
service uses one library; the server runs separately and every service connects to it.

## Server

The published image contains the gRPC listener, the dashboard, the HTTP API and the event browser.

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  snodra/snodra-server:0.6.0
```

| Port | Purpose |
|---|---|
| `7000` | gRPC, where services connect |
| `7001` | HTTP: the dashboard at `/ui/`, the API at `/api/v1/` |

Nothing else is needed: telemetry is off unless `SNODRA_SERVER_OTLP_ENDPOINT` names a collector.
Pin the tag you deploy.

No Docker? Every [release](https://github.com/snodra/snodra-server/releases) ships the binary for
Linux (static musl, and gnu), macOS and Windows, on amd64 and arm64:

```sh
curl -fsSL -o snodra-server.tar.gz \
  https://github.com/snodra/snodra-server/releases/download/v0.6.0/snodra-server-v0.6.0-x86_64-unknown-linux-musl.tar.gz
tar xzf snodra-server.tar.gz && ./snodra-server
```

Replace `0.6.0` with another release when you upgrade; `latest` exists, but a fixed tag keeps a restart reproducible.

Check it:

```sh
curl -s localhost:7001/api/v1/version
```

The image is distroless and has no shell. Its `HEALTHCHECK` runs `/app/snodra-server
--health-check`, which probes the gRPC health service and exits `0` when it is `SERVING`.

Next: [the server quick start](/docs/server/quickstart/) for health, the dashboard and a first
request, and [server settings](/docs/server/configuration/server/) for every environment variable.

## Kotlin

The starter is a Spring Boot library. Add the core artifact and one event store and one message
store add-on:

```kotlin
// build.gradle.kts
repositories {
    mavenCentral()
}

dependencies {
    implementation("com.damoreira.snodra:snodra-messaging:0.6.1")
    implementation("com.damoreira.snodra:snodra-messaging-kafka:0.6.1")   // or snodra-messaging-rabbitmq
    implementation("com.damoreira.snodra:snodra-messaging-mongo:0.6.1")   // or snodra-messaging-jdbc
    testImplementation("com.damoreira.snodra:snodra-messaging-test:0.6.1")
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
[the Kotlin quick start](/docs/messaging/kotlin/quickstart/).

Next: [the Kotlin quick start](/docs/messaging/kotlin/quickstart/), then
[configuration](/docs/messaging/kotlin/configuration/) and [add-ons](/docs/add-ons/).

## Rust

The crate and its add-ons come from crates.io:

```sh
cargo add snodra-messaging@0.8
cargo add snodra-messaging-kafka@0.8        # or snodra-messaging-rabbitmq
cargo add snodra-messaging-mongo@0.8        # or snodra-messaging-sqlx with a database feature
```

| Crate | Use |
|---|---|
| `snodra-messaging` | The hub client, events, processors, sagas and identity |
| `snodra-messaging-kafka` | Kafka event store, and partner topics as external sources |
| `snodra-messaging-rabbitmq` | RabbitMQ Streams event store |
| `snodra-messaging-mongo` | MongoDB message store |
| `snodra-messaging-sqlx` | SQL message store for PostgreSQL and MySQL (`postgres` or `mysql` feature) |

The SQL crate takes its database from its features:

```toml
snodra-messaging-sqlx = { version = "0.7", default-features = false, features = ["postgres"] }
```

For tests, enable the library's `testing` feature in dev-dependencies:

```toml
[dev-dependencies]
snodra-messaging = { version = "0.8", features = ["testing"] }
```

Next: [the Rust quick start](/docs/messaging/rust/quickstart/), then
[configuration](/docs/messaging/rust/configuration/) and [add-ons](/docs/add-ons/).

## Go

The Go library is pre-1.0 and at feature level 1: commands and queries, in every query mode, with no events, stores or
sagas yet. It needs Go 1.26 or later:

```sh
go get github.com/snodra/snodra-messaging-go@latest
go get github.com/snodra/snodra-messaging-go/observability@latest   # optional: OpenTelemetry metrics and traces
```

The package is named `snodra`; import it as `snodra "github.com/snodra/snodra-messaging-go"`. The core module depends
only on gRPC and protobuf.

Next: [the Go quick start](/docs/messaging/go/quickstart/), then
[configuration](/docs/messaging/go/configuration/).

## After installation

[Your first service](/docs/getting-started/first-service/) walks through the shortest path from a running server to a
registered handler. If you are upgrading an existing deployment, read
[Upgrades](/docs/operations/upgrades/) before you change coordinates.

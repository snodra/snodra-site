# Testing

Test at three levels: a handler in memory, a service against real stores, and a client library
against the conformance contract. Snodra ships a kit for each.

## Handlers and sagas, in memory

=== "Kotlin"

    Add `com.damoreira.snodra:snodra-messaging-test:0.6.1` as a test dependency. It provides
    `InMemoryBuses` (a real `EventBus`, `CommandBus` and `QueryBus` without Docker),
    `InProcessHub` (a fake hub with permits, queues and all query modes), `SnodraContainers` and
    `SagaTestFixture`.

    ```kotlin
    val buses = InMemoryBuses(typePrefix = "orders")
    buses.register(OrderHandlers(buses))
    buses.sendBlocking(PlaceOrder("o-1"))
    ```

=== "Rust"

    Enable the `testing` feature of `snodra-messaging-rs` in dev-dependencies. It provides
    `SagaTestFixture`, `InMemoryStores` and the in-memory event and message stores.

    ```rust
    let stores = InMemoryStores::new();
    let app = stores.install(SnodraMessaging::builder(stores.config("orders")).await?).start().await?;
    ```

Both fixtures run the library's own runtime, so a passing saga test behaves like the real one. The
in-memory buses do not commit or use credits; they are for unit tests, not for proving delivery.

## A service against real infrastructure

Use Testcontainers for Kafka, MongoDB, RabbitMQ and the server image. The Kotlin kit's
`SnodraContainers` starts the hub image (default `snodra-server:dev`, or `SNODRA_SERVER_IMAGE`), a
single-node MongoDB replica set and Kafka. The Rust suites do the same with the server's released
image. This is where you test transactions, the outbox relay, competing instances and processor
control.

Reference: [Kotlin testing](../messaging/kotlin/testing.md) and
[Rust testing](../messaging/rust/testing.md).

## A client library against the contract

The [conformance runner](../tools/conformance-runner.md) proves that a client library reaches feature
level 1: the handshake, registration, flow control, deadlines, the query modes, failover,
credentials and TLS. It runs fake hubs in the runner and, for the checks that need one, a real
server. Use it when you write a library in another language, or when you change a library's hub
client.

## What to assert

| Level | Assert |
|---|---|
| Handler | The reply, the events published, the state written |
| Saga | The commands sent, the deadlines scheduled, the final state |
| Service | The outbox entry and the state commit or roll back together; a duplicate event is skipped |
| Processors | Pause, resume, reset and replay; a poison record becomes a dead letter |
| Client | Every conformance check passes, including the two-server failover |

Do not test the server's routing with a fake hub alone; the fake hub is intentionally close but not
identical. Keep at least one end-to-end test against the real image.

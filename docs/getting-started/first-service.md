# Your first service

This walkthrough connects one service to a running server and sends it a command. It links the
existing quickstarts for the code instead of repeating them: the Kotlin and Rust pages are the
reference for handlers and buses.

## Before you start

- Docker, for the server.
- A JVM with Gradle, or a Rust toolchain, depending on the service you write.
- A Kafka broker or a RabbitMQ Streams cluster for events, and MongoDB or PostgreSQL/MySQL for the
  message store. The quickstarts assume Kafka and MongoDB; substitute the stores you run. A service
  that only answers commands and queries needs neither store.

## 1. Start the server

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  snodra/snodra-server:0.5.0
```

Open <http://localhost:7001/ui/>. The topology is empty until a service registers. If the port is
taken on macOS, see [the quick start](../server/quickstart.md) for the AirPlay note.

## 2. Create the service

=== "Kotlin"

    Follow [the Kotlin quick start](../messaging/kotlin/quickstart.md) through the dependency and
    the handler. The starter discovers `@CommandHandler`, `@QueryHandler` and `@EventHandler`
    methods and registers their types on connect.

    Set the service name and the server address in `application.yml`:

    ```yaml
    snodra:
      messaging:
        service-name: orders
        hub:
          address: static://localhost:7000
    ```

=== "Rust"

    Follow [the Rust quick start](../messaging/rust/quickstart.md) through the builder and the
    handler. A closure passed to `.command(...)`, `.query(...)` or `.event(...)` is the handler; the
    builder opens the hub stream and registers the types.

    ```sh
    export SNODRA_SERVICE_NAME=orders
    export SNODRA_SERVER_ADDRESS=static://localhost:7000
    ```

## 3. Declare one command and one event

Both quickstarts show the message types. Keep the naming rules in mind: a wire type is
`<service-prefix>.<ClassName>`, commands are imperative, events are past tense. The type name is the
routing key — the server matches a request to a handler by it.

See [the messaging model](../messaging/index.md) for naming, the Kafka/RabbitMQ layout and the
outbox, and [Commands](../concepts/commands.md) for what a handler may assume.

## 4. Send the command

Start the service, wait for it to register, and send through the library's command bus, or from
another service with the same client. The topology should now list the service, its instance and
the command type. A request with no live handler fails immediately with `NO_HANDLER`; it is not
queued.

## 5. Watch what happened

- **Topology** shows instances, handled types and queue depth.
- **Processors** shows each event processor, its lag and its dead letters.
- **Events** searches the event store for the event your handler published.

See [Dashboard](../server/dashboard.md), [Event processors](../server/event-processors.md) and
[Event browser](../tools/event-browser.md). If the event never appears, check the outbox and the event
store's settings in [Add-ons](../add-ons/index.md).

## 6. Where to go next

| Goal | Page |
|---|---|
| Add authentication | [Authentication](../server/configuration/index.md) |
| Choose the stores | [Add-ons](../add-ons/index.md) |
| Add a saga | [Sagas](../concepts/sagas.md), then [Rust sagas](../messaging/rust/sagas.md) |
| Test the service | [Testing](../operations/testing.md) |
| Run it in a container | [Containers](../integrations/containers.md) |
| Tune queues and deadlines | [Tuning](../operations/tuning.md) |

# snodra-messaging (Kotlin)

The Spring Boot starter that gives a Kotlin service the same messaging model as the rest of the
stack: an `EventBus`, `CommandBus` and `QueryBus` over Kafka and the hub, annotated handlers, a
transactional outbox, idempotent consumers, sagas, and Testcontainers helpers.

```kotlin
implementation("com.damoreira.snodra:snodra-messaging:<version>")
testImplementation("com.damoreira.snodra:snodra-messaging-test:<version>")
```

## What it gives you

- One `@EventHandler`, `@CommandHandler` or `@QueryHandler` per method; discovery and registration are
  automatic.
- Events through an outbox in the same message-store transaction as your state; commands and
  queries over the hub.
- Idempotent consumers (`processed_events` markers), dead letters, named event processors and sagas
  with deadlines.
- The hub connection: registration, reconnect, heartbeats, flow control, timeouts, token/JWT/mTLS.
- Test helpers: an in-memory bus, a fake hub and Testcontainers fixtures.

## Pages

- [Quick start](quickstart.md) — dependency, first handler, first send.
- [Configuration](configuration.md) — properties, environment variables and every hub credential.
- [API](api.md) — handlers, buses, query modes, sagas, processors and dead letters.
- [Testing](testing.md) — the in-memory harness and Testcontainers.
- [Modules and build](modules.md) — artifacts, Gradle, CI and examples.

## Limitations

- Maven artifacts are on Maven Central; pin the version you deploy. The starter targets Spring Boot 4
  and Kotlin 2.4; older lines are untested.
- Events are JSON objects in one Kafka topic; very large payloads belong in object storage, not the
  event.
- No event sourcing: state is a document, the outbox guarantees the event.

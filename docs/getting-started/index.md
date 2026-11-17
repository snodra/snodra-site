# Getting started

Three entry points, one stack. Pick the one that matches what you are building.

| Entry point | What you get | Start here |
|---|---|---|
| **Server image** | The gRPC router, the dashboard, processor control and the event browser | [Installation: server](installation.md#server) |
| **Kotlin library** | A Spring Boot starter: buses, handlers, outbox, sagas, testing kits | [Installation: Kotlin](installation.md#kotlin) |
| **Rust library** | A crate: one builder for the hub client, event store, outbox and handlers | [Installation: Rust](installation.md#rust) |

A first system needs two things: a server, and at least one service that registers a handler. The
walkthrough in [Your first service](first-service.md) links the existing quickstarts instead of
repeating them.

## The shape of a first setup

```text
your service (Kotlin or Rust)
        │  commands and queries over gRPC :7000
        ▼
  Snodra Server  ── dashboard and API :7001
        ▲
        │  events through the outbox
        ▼
  event store (Kafka or RabbitMQ Streams) + message store (MongoDB or SQL)
```

The server keeps no state: it holds an in-memory registry of the types each live instance handles.
Events never pass through it. See [the messaging model](../messaging/index.md) for the complete
picture, and [Add-ons](../add-ons/index.md) for the store choices.

## Next

- [Installation](installation.md) — the server image, the Kotlin artifact and the Rust crate.
- [Your first service](first-service.md) — from an empty directory to a registered handler.
- [Core concepts](../concepts/index.md) — if CQRS is new to you, read this before the reference.

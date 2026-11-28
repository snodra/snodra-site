---
title: "Getting started"
---

Five entry points, one stack. Pick the one that matches what you are building.

| Entry point | What you get | Start here |
|---|---|---|
| **Server image** | The gRPC router, the dashboard, processor control and the event browser | [Installation: server](/docs/getting-started/installation/#server) |
| **Kotlin library** | A Spring Boot starter: buses, handlers, outbox, sagas, testing kits | [Installation: Kotlin](/docs/getting-started/installation/#kotlin) |
| **Rust library** | A crate: one builder for the hub client, event store, outbox and handlers | [Installation: Rust](/docs/getting-started/installation/#rust) |
| **Go library** | A module at feature level 4 (0.7.0): commands and queries in every query mode, events through the outbox and event stores, processors with status, control, reset and replay and dead letters, and sagas, deadlines and idempotent external calls | [Installation: Go](/docs/getting-started/installation/#go) |
| **Python library** | A package at feature level 4 (0.8.0): commands and queries in every query mode, events through the outbox and event stores, processors with status, control, reset and replay and dead letters, and sagas, deadlines and idempotent external calls | [Installation: Python](/docs/getting-started/installation/#python) |

A first system needs two things: a server, and at least one service that registers a handler. The
walkthrough in [Your first service](/docs/getting-started/first-service/) links the existing quickstarts instead of
repeating them.

## The shape of a first setup

```text
your service (Kotlin, Rust, Go or Python)
        │  commands and queries over gRPC :7000
        ▼
  Snodra Server  ── dashboard and API :7001
        ▲
        │  events through the outbox
        ▼
  event store (Kafka or RabbitMQ Streams) + message store (MongoDB or SQL)
```

The server keeps no state: it holds an in-memory registry of the types each live instance handles.
Events never pass through it. See [the messaging model](/docs/messaging/) for the complete
picture, and [Add-ons](/docs/add-ons/) for the store choices.

## Next

- [Installation](/docs/getting-started/installation/) — the server image, the Kotlin artifact, the Rust crate, the Go module and the Python package.
- [Your first service](/docs/getting-started/first-service/) — from an empty directory to a registered handler.
- [Core concepts](/docs/concepts/) — if CQRS is new to you, read this before the reference.

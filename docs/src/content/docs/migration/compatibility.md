---
title: "Compatibility"
---

`snodra.hub.v1` is the protocol package. This page states what it guarantees, so you can decide what
may be rolled independently and what must move together.

## One version, no negotiation

The server and the client libraries ship as one release train. `Register` carries `client_version` for
diagnostics, not for capability negotiation: the server has no branches for older clients, and a
server and a client of different builds are not supported. Every session has every feature — flow
control, query modes, status reports, credential refresh, processor control.

The package name is the boundary. A change that is not compatible belongs in a new package, and a
server and its clients must be on the same side of it.

## What the package guarantees

| Guarantee | Meaning |
|---|---|
| **One stream per instance** | `Hub.Connect`, first message `Register`, answered by `RegisterAck` |
| **One terminal message per request** | A `Reply` or an `Error`; for multi-part modes, `ReplyPart`s and one `ReplyEnd` |
| **Stable error codes** | `NO_HANDLER`, `TIMEOUT`, `HANDLER_DISCONNECTED`, `INVALID_REQUEST`, `RESOURCE_EXHAUSTED`, `CANCELLED`, `UNAUTHENTICATED`, `PERMISSION_DENIED` |
| **Opaque payloads** | The server never decodes, logs or persists a payload; bytes are forwarded unchanged |
| **Type-based routing** | One exclusive owner per command/query type, or a shared type with several owners |
| **Deadlines** | The request's `timeout_ms`, a per-type override, or the default; a late reply is dropped |
| **Flow control** | A request is forwarded only while the target instance has a permit |
| **Reconnect** | A stream end is recoverable; in-flight requests fail with a defined code |
| **Reserved names** | `snodra.events.*` types, the `snodra.hub.v1.Hub` health name, the `snodra://service/<name>` SAN |

## What it does not guarantee

- **Mixed builds.** There is no compatibility window inside a protocol package.
- **Exactly-once delivery.** At-least-once plus processed-event markers; see
  [Consistency](/docs/concepts/consistency/).
- **Payload schema.** JSON is the convention, and the owning service's `*-api` module or documented
  contract defines the shape. The server does not validate it.
- **Global ordering.** Order is per key within an event store.
- **Durability of a command.** A command that times out may or may not have run.
- **Broker resources.** The libraries do not create topics, super streams, collections or tables.

## Data compatibility

Within `snodra.hub.v1`, the stored data keeps its shape:

- **Event store**: the record's key, headers and value; the topic `snodra.events` and its `.dlt`
  companion; consumer groups `<service>.<processor>`.
- **MongoDB**: collections `outbox`, `processed_events`, `dead_letters`, `processor_control`,
  `external_calls`, `sagas`, `saga_dispatch`, `deadlines`, `saga_failures`, with explicit fields and
  no `_class`.
- **SQL**: schema version `1`; the tables are `snodra_*`, with explicit columns, indexes and values.

A Kotlin and a Rust instance can share one event store and one message store. That is a supported
layout, not a compatibility accident: the two libraries are tested against the same record and
document contracts.

## Read next

- The complete contract: [Protocol](/docs/server/protocol/).
- The failure table: [Lifecycle](/docs/server/lifecycle/).

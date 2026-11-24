---
title: "Queries"
---

A query asks for data and returns it. `catalog.GetItem`, `billing.FindInvoice` and
`catalog.ListFiles` are queries. A query never changes state, and the server routes it by type just
like a command.

## Four answer shapes

| Mode | Who answers | Use it when |
|---|---|---|
| **Point query** | one live instance of the owning service | you need one answer from one place |
| **Scatter-gather** | every instance of every owner of a *shared* query type | you need a partial or complete view across services |
| **Streaming query** | one instance, as a stream of parts under the collector's credit | the result is large or slow to produce |
| **Subscription query** | every live target at the open, then pushed updates | a screen needs an initial result and changes |

A type is either **exclusive** (one owning service, the default) or **shared** (several services may
own it). Every registrant must declare the same kind; a mismatch is rejected at registration. A
point query on a shared type goes to one instance of any owner; a scatter-gather on an exclusive
type asks every instance of its one owner.

## What a caller must handle

- **`NO_HANDLER`** when no target is live. Partial answers are answers: a scatter-gather succeeds
  even when some parts failed, so check its `failed` and `timedOut` counts.
- **`TIMEOUT`** when the deadline passes. The answer may still arrive late; the server drops it.
- **`HANDLER_DISCONNECTED`** when the target leaves. A query is safe to retry; it changed nothing.
- **Back-pressure** on streams and subscriptions. A slow reader ends with an error rather than
  growing a buffer without bound.

Queries are the read side, so they may read a projection, a cache or the service's own database.
Snodra does not require a particular read model; see [CQRS](/docs/concepts/cqrs/) and
[Event sourcing](/docs/concepts/event-sourcing/).

## Where it is implemented

- The query modes and their wire rules: [Protocol: query modes](/docs/server/protocol/#query-modes).
- The Kotlin API: [Kotlin API](/docs/messaging/kotlin/api/).
- The Rust API: [Rust API](/docs/messaging/rust/api/).
- Shared types and registration: [the messaging model](/docs/messaging/).
- Stream and subscription limits: [Server settings](/docs/server/configuration/server/).

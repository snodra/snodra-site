---
title: "Sagas"
---

A saga is a long-running process that reacts to events, keeps state between them, sends commands to
other services and can wait for time to pass. Use one when a business process spans services and
takes longer than one request: an order that waits for payment, a banner job that fails if the
printer stays silent for 30 seconds.

## What a saga does

1. **Starts** on an event, and records associations (for example order id to saga id).
2. **Handles** further events for the same associations.
3. **Sends commands** through the hub and receives `SagaCommandFailed` when one fails.
4. **Schedules deadlines**, such as "check again in 30 seconds" or "give up at noon".
5. **Ends**, or stays active until its retention removes it.

The saga's state lives in the message store, so it survives restarts and is shared by the service's
instances. A relay delivers the commands a saga recorded, with retries and a lease that lets another
instance take over after a crash.

## What it is not

The server is not a workflow engine: it does not run sagas, store their state or schedule their
deadlines. That work belongs to the service's library and its message store. A saga is also not a
distributed transaction: each step commits on its own, and compensation is a command you send.

```text
OrderPlaced ──▶ saga ──▶ ReserveStock (command)
                   │
                   ├── StockReserved ──▶ saga ──▶ ConfirmOrder
                   └── deadline ──────▶ saga ──▶ CancelOrder
```

## Design rules

- Make a saga's command handlers idempotent; a relay may deliver a command more than once.
- Use associations, not shared mutable state, to find the saga.
- Prefer a deadline over a polling loop.
- End the saga explicitly; ended sagas are kept only for `sagas.ended-retention`.

## Where it is implemented

- The saga runtime, store and tests: [the messaging model](/docs/messaging/).
- Kotlin: [Kotlin API](/docs/messaging/kotlin/api/) and the saga fixture in
  [Testing](/docs/operations/testing/).
- Rust: [Sagas](/docs/messaging/rust/sagas/).
- Go: [Go API](/docs/messaging/go/api/#sagas-and-deadlines) and [Go quick start](/docs/messaging/go/quickstart/).
- Python: [Python API](/docs/messaging/python/api/#sagas-and-deadlines) and
  [Python quick start](/docs/messaging/python/quickstart/).
- The store that holds saga state: [MongoDB message store](/docs/add-ons/mongodb-message-store/) or
  [SQL message store](/docs/add-ons/sql-message-store/).
- What survives a failure: [Consistency](/docs/concepts/consistency/).

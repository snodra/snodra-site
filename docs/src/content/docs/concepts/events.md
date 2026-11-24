---
title: "Events"
---

An event states that something happened: `orders.OrderPlaced`, `billing.InvoiceIssued`. Events are
past tense because they describe a fact. A service publishes them; any number of services may react.

## Where events go

Events do not pass through the server. A handler writes its state change and an outbox entry in the
same transaction. A relay then publishes the outbox entry to the event store — Kafka or RabbitMQ
Streams — and consumers read from there. That is what makes the write and the event atomic: either
both are committed or neither is.

```text
handler ──transaction──▶ state + outbox
                               │ relay
                               ▼
                        event store ──▶ processor A
                                    └─▶ processor B
```

## What a consumer can rely on

| Guarantee | Detail |
|---|---|
| **At-least-once delivery** | A consumer may see an event more than once after a crash or a rebalance. |
| **Duplicate suppression** | Processed-event markers in the message store let the library skip an event it already handled. |
| **Ordering per key** | Events published with the same key keep their order. There is no global order across keys or partitions. |
| **No cross-service transaction** | The publisher commits, then the event travels. Other services see it later. |
| **A dead letter on failure** | A record that cannot be handled is parked in the message store or `<topic>.dlt`, not silently dropped. |

The key is chosen by the publisher and is usually the aggregate id. Use it whenever the order of two
events matters. The event's headers carry the type, id, timestamp, source, correlation id and trace
context; the payload is service-owned JSON.

## Event or command?

Use an event when the sender does not care who reacts, or whether anyone does. Use a command when
exactly one service must do something and the caller needs the result. A saga connects the two: it
reacts to events and sends commands. See [Sagas](/docs/concepts/sagas/).

## Where it is implemented

- The event record, headers and the Kafka/RabbitMQ layout:
  [the messaging model](/docs/messaging/).
- The event stores: [Add-ons](/docs/add-ons/).
- Processors, lag and dead letters: [Event processors](/docs/concepts/event-processors/) and
  [Event processors reference](/docs/server/event-processors/).
- Delivery and duplicate rules: [Consistency](/docs/concepts/consistency/).

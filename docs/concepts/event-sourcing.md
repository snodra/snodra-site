# Event sourcing

Event sourcing stores every state change as an event and rebuilds state by replaying them. Snodra
uses events, but **it is not an event-sourcing framework**. This page makes the boundary explicit so
you know what you have to build yourself.

## What Snodra stores

| Data | Where | Who owns it |
|---|---|---|
| Events | the event store (Kafka or RabbitMQ Streams) | the broker's retention policy |
| Outbox entries | the message store | the library; purged after `outbox.retention` |
| Processed-event markers | the message store | the library; purged after `idempotency.retention` |
| Dead letters | the message store, or `<source>.dlt` | the library; retention applies |
| Saga state, deadlines and dispatch | the message store | the saga runtime |
| Your domain state | **your database** | you |

The event store keeps events for as long as the broker keeps them. The message store keeps the
plumbing that makes delivery reliable. Neither stores an aggregate snapshot or an aggregate's
version history for you.

## What is not there

- **No aggregate repository.** There is no `load(id)` that replays an aggregate's events. Your
  command handler loads and writes its own rows or documents.
- **No automatic projection rebuild.** A read model is code you write, reading events through a
  processor.
- **No global event history by default.** You can search and tail events with the event browser, and
  replay a processor, but that is an operational tool, not a domain API.
- **No state derived only from events.** A service that loses its database cannot recover its state
  from the event store alone unless you build that.

## What you can build on it

The event store is a durable, ordered log, so you can build event sourcing on top: keep one stream
per aggregate key, write events with that key, and replay from the beginning into a new projection.
The libraries give you the processors, markers and replay controls; the aggregate model and its
snapshots remain yours.

## Where it is implemented

- The event store and its layout: [Kafka event store](../add-ons/kafka-event-store.md) and
  [RabbitMQ Streams event store](../add-ons/rabbitmq-streams-event-store.md).
- The outbox, markers and retentions: [the messaging model](../messaging/index.md) and
  [MongoDB message store](../add-ons/mongodb-message-store.md).
- Reading and replaying events: [Event browser](../tools/event-browser.md) and
  [Processor control](../server/processor-control.md).

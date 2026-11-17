# Event processors

An event processor is a named consumer of the event store. Every handler without an explicit
processing group belongs to `default`; handlers in a group share one. Each processor has its own
consumer group, `<service>.<processor>`, and its own position in the log.

## Why name them

| Reason | Effect |
|---|---|
| Independent progress | A slow projection does not hold back a fast one. |
| Independent pause and replay | You can stop, reset or replay one processor without touching the others. |
| Clear operations | Lag, dead letters and state are reported per processor. |
| Ordering per key | Each processor sees a key's events in order within its partitions. |

## What happens to a record

1. The consumer reads a record from its group.
2. The library checks the processed-event marker. If it exists, the record is skipped as a duplicate.
3. The handler runs inside a transaction with the marker and any outbox entries it writes.
4. On success the offset is committed and the marker is stored.
5. On failure the record is retried, then parked as a dead letter — in the message store, or in
   `<source>.dlt` when the store supports a native dead-letter topic.

That is why a handler must be safe to run twice: at-least-once delivery plus a marker gives an
effectively-once result only if the handler does not have side effects outside the transaction. Put
an external call behind an idempotent handler or a saga command.

## Watching and controlling one

- **Status** is what each instance reports every five seconds: state, assigned partitions, lag,
  processed and failed counts, last error.
- **Control** can pause, resume, reset or replay a processor through the dashboard or the HTTP API.
- **Dead letters** can be listed, retried or discarded; a retry runs the handler again and removes
  the letter only when it succeeds.

A processor is `RUNNING`, `PAUSED`, `STARTING`, `FAILING` or `STOPPED`. The server shows the worst
state over the instances that report the processor.

## Where it is implemented

- The reference: [Event processors](../server/event-processors.md).
- Pause, resume, reset, replay and dead letters: [Processor control](../server/processor-control.md).
- Modes and retention: [the messaging model](../messaging/index.md).
- Kotlin and Rust handles: [Kotlin API](../messaging/kotlin/api.md),
  [Rust API](../messaging/rust/api.md).
- Delivery rules: [Consistency](consistency.md).

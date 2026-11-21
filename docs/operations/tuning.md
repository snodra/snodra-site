# Tuning

Most Snodra tuning is about three things: how much work an instance may queue, how long a caller
waits, and how many handlers run at once. Change one knob at a time and measure the queue, not the
average latency alone.

## The capacity knobs

| Server setting | Default | Bounds |
|---|---|---|
| `SNODRA_SERVER_QUEUE_CAPACITY_PER_INSTANCE` | `10000` | Requests queued for one instance before new ones are rejected |
| `SNODRA_SERVER_QUEUE_BYTES_PER_INSTANCE` | `64MiB` | Encoded bytes queued for one instance |
| `SNODRA_SERVER_QUEUE_BYTES_TOTAL` | `512MiB` | Encoded bytes queued over all instances |
| `SNODRA_SERVER_SESSION_BUFFER` | `1024` | Outbound messages per session |
| `SNODRA_SERVER_SUBSCRIPTION_BUFFER` | `256` | Updates held for a subscriber that owes credit |
| `SNODRA_SERVER_MAX_SUBSCRIPTIONS_PER_INSTANCE` | `1024` | Subscriptions one handler instance serves |

A full queue answers `RESOURCE_EXHAUSTED` immediately; it does not wait. That is deliberate: a
caller can retry a request that never ran, while a request parked in an unbounded queue would just
age out at its deadline. Watch `snodra_server_rejected_total{reason}` and
`snodra_server_queue_wait_seconds` before raising the limits — a bigger queue moves the failure from
rejection to latency.

## Permits and handler concurrency

Each service announces how many requests it can take (`hub.max-concurrent-handlers` in Kotlin,
`SNODRA_MAX_CONCURRENT_HANDLERS` in Rust, 256 by default). The server sends a request only while the
instance has a permit; permits return as handlers complete. Set the value to what the handler can
actually run at once, not to the thread pool size. A one-permit instance is no longer capped at
about 20 requests per second, but it is still one-at-a-time.

`hub.load-factor` weights an instance's share of unkeyed routing; use it to drain a weaker node.
`hub.priorities.<type>` (Kotlin) or `SNODRA_SERVER_PRIORITIES` (Rust) makes selected types jump a
busy queue. Both only reorder work that is already waiting.

## Deadlines

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_SERVER_DEFAULT_TIMEOUT_MS` | `5000` | Used when the request sends `timeout_ms = 0` |
| `SNODRA_SERVER_MAX_TIMEOUT_MS` | `60000` | Upper clamp for a client-chosen timeout |
| `SNODRA_SERVER_TIMEOUT_OVERRIDES` | none | Per-type override, `type=ms,type=ms` |
| `SNODRA_SERVER_MAX_STREAM_DURATION` | `10m` | Longest streaming query |
| `SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION` | `0` | Longest subscription; `0` is unlimited |

Clients send `timeout_ms = 0` unless the caller chose one, so an override applies without touching
the service. Prefer an override for the few genuinely long calls (a file upload, a report) over
raising the global default. A timeout is not a retry signal for commands: the handler may have run.

## Throughput floors

These are the behaviours the design already guarantees or has measured; use them as regression
floors, not as targets:

| Floor | Value | Source |
|---|---|---|
| Registration after a hub is reachable again | within 5 s | reconnect backoff cap and jitter |
| Dead instance detection | about 10–11 s | heartbeat 3 s, timeout 10 s |
| One-permit handler | not capped at ~20 requests/s | batched permit grants |
| RabbitMQ Streams publish / consume, local broker | about 1 700 / 6 700 events per second | the add-on's measurement |

Measure your own system with its own payloads. A throughput number without the payload size, the
store and the number of partitions is not comparable.

## Consumer side

For events, the limit is usually the consumer, not the server. A processor's lag
(`snodra_processor_lag`) shows whether the handler or the store is the bottleneck. Add partitions to
increase parallelism, not more instances on the same partition count: one partition is consumed by
one instance per processor. RabbitMQ Streams stores offsets periodically, so a crash can redeliver up
to `offset-store-messages` (10 000) or `offset-store-interval` (5 s) per partition; the markers make
that a cost, not a correctness problem.

## Read next

- Every server setting: [Server settings](../server/configuration/server.md).
- Client retry and timeout keys: [Kotlin configuration](../messaging/kotlin/configuration.md) and
  [Rust configuration](../messaging/rust/configuration.md).
- Flow control and deadlines on the wire: [Protocol](../server/protocol.md).
- The metrics to watch: [Monitoring](monitoring.md).

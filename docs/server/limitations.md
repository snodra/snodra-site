# Limitations and future work

What the hub deliberately does not do, and what is planned next.

## Known limitations

- **The hubs only detect, never repair, a registration that differs between them**
  ([High availability](operations.md#high-availability)). With a single hub, a hub restart still fails every
  synchronous call for the few seconds it takes to come back.
- **Access control is opt-in.** In mode `off` (the default) the hub exposes port 7000 (gRPC)
  and port 7001 (the dashboard and its API) unauthenticated, in plain text, for the
  private network only: any process that can reach port 7000 can register as any service and
  receive its commands, and the dashboard and its API disclose service names, instance ids,
  handled type names, the hub's settings and per-edge request counts and latencies (no payloads
  or headers). `enforce` mode with the ACL, TLS and a dashboard token closes **these**: registering
  as a service without its token, handling or sending a type the token's entry does not list,
  taking over another service's instance id (and with it that service's queued requests and
  replies), reading the traffic and the tokens on the wire, and reading the topology (which lists
  instance ids) without the dashboard token or, on gRPC, an ACL token
  ([Access control](configuration/index.md), 06-security.md).
  It does **not** close: a stolen token (it works until its ACL entry is removed), a service
  sending or handling what its own entry allows, a permitted sender forwarding any `authorization`
  header, a hub left in `off` or `permissive` (which refuse only a takeover), or the HTTP topology when no dashboard
  token is set.
  Both libraries send the token, so `enforce` works with every service that has a token in its ACL
  entry ([Client configuration](https://snodra.damoreira.com/server/configuration/mtls/)).
  Request contents are still protected by the forwarded JWT, which the handler validates; the
  ACL does not replace it. A static token is a long-lived secret per service (JWT credentials and client
  certificates shorten that).
- **Not durable.** A command that times out may or may not have been handled.
- **A subscription's targets are fixed at its open** (updates at most once): an instance that
  registers later never serves it, a target that leaves is not replaced, and the sender learns
  of it only when the last target leaves. The libraries do not resubscribe (a caller that needs
  every instance subscribes again).
- **Processor status is what the instances report** ([Event processors](event-processors.md)): a
  consumer group without a live member does not appear there; the [event browser](event-browser.md)'s consumer groups
  show its lag from Kafka.
- **The event browser scans** ([Event browser](event-browser.md)): a search reads partitions backwards within its budgets,
  so a rare record far back may take several pages; it reads plaintext Kafka only. With the payload switch on, a leaked
  dashboard or write token reads every payload on the configured topics.
- **Processor control reaches only the instances that reported the processor**
  ([Processor control](processor-control.md)). An instance that has not reported its status yet is not prepared; its consumer makes the execute fail
  with `GROUP_NOT_EMPTY` (nothing changed when the members check catches it; when it joins after the reset handlers ran,
  Kafka's refusal of the commit says what changed). The hub runs one reset per processor at a time and keeps nothing: a reset
  in progress when it restarts is released by the lease (up to 30 s), not finished.

## Future work

- A hub that retries a credentials refresh it could not
  judge (a rotated key still being fetched) when the fetch completes, instead of waiting for the
  client's next renewal. Certificate revocation checks (CRL, OCSP) if short-lived certificates turn
  out not to be enough.
- Optional Kafka-backed command buffering for `NO_HANDLER` cases.
- The resilience improvements, below.

### Resilience

Measured on 2026-10-30 with the examples sandbox (`snodra-messaging/examples`, see
[Hub quick start](quickstart.md)): service A calling
service B through the hub while B was stopped, killed mid-request, and cut off the network. The
table shows how the hub and libraries behave now.

| Scenario | Snodra Server | Notes |
|---|---|---|
| Handler stopped cleanly | `NO_HANDLER`, immediate; nothing queued | The handler never ran, so a command may be retried at once. |
| Handler lost mid-request | `HANDLER_DISCONNECTED`; outcome unknown, the caller decides | The handler may have run; retry only with an idempotent handler and the same business command id. |
| Handler alive but unreachable (partition, frozen JVM) | heartbeat every 3 s, evicted after 10 s (checked every second); HTTP/2 keepalive from the client too (10 s / 5 s, while idle) | **closed (F1)**: a call whose timeout exceeds 10 s ends with `HANDLER_DISCONNECTED` after ~10-11 s instead of waiting 30 s. |
| Client reconnect after a drop | exponential backoff 500 ms → 5 s with ±20 % jitter, reset once an attempt reaches the handshake | **closed (F2)**: a healed service is back within 5 s of the hub being reachable. |
| Request timeout default | 5 s hub default, per-type overrides (`SNODRA_SERVER_TIMEOUT_OVERRIDES`), clamp 60 s; clients send 0 unless the caller chose a timeout | Short timeouts suit a BFF-driven system; long-running types get an override (F4). |
| Busy handler (no free capacity) | flow control: handlers grant `max-concurrent-handlers` permits and one per completed handler; the hub queues up to 10 000 requests or 64 MiB per instance, by priority then age, each with its own deadline; beyond that `RESOURCE_EXHAUSTED` (`HandlerBusyException`) | **closed (F3)** |
| Caller-side retry | opt-in `RetryPolicy` in both libraries, transient codes only, fresh request id per attempt, within the caller's time budget | **closed (F5)** |

Improvements, in the order they are worth doing:

| Id | Feature | Change | Notes |
|---|---|---|---|
| F1 | **Faster dead-peer detection** — **done** | Hub: sessions are evicted after 10 s (`SNODRA_SERVER_HEARTBEAT_TIMEOUT`) and told to heartbeat every 3 s (`SNODRA_SERVER_HEARTBEAT_INTERVAL`, `RegisterAck`). Clients: interval from the ack, HTTP/2 keepalive pings 10 s / 5 s also while idle. | Costs one tiny frame every 3 s per instance and a higher false-positive risk under long GC pauses: with a 3 s cadence and a 10 s timeout, a pause of about 7-10 s (depending on where in the heartbeat cycle it starts) can already evict, which is why the timeout stays at three intervals or more. Sandbox smoke step 10 pauses service-b and expects the failure in about 10 s. |
| F2 | **Bounded reconnect backoff** — **done** | Clients: `reconnect-backoff.max` 30 s → 5 s, ±20 % jitter (the jittered wait never exceeds the maximum), backoff back to the floor once an attempt reached the handshake (the ack). | A 5 s cap keeps the thundering-herd protection for a hub restart while bringing a healed service back within seconds; the client libraries' tests assert re-registration within 5 s of a hub restart. |
| F3 | **Per-handler flow control (permits)** — **done** | Protocol: `Register.initial_permits`, `Permits{count}`, `Request.priority`, `ErrorCode.RESOURCE_EXHAUSTED`. Hub: per-instance queue (priority, then age) with `SNODRA_SERVER_QUEUE_CAPACITY_PER_INSTANCE` (10 000) and `SNODRA_SERVER_QUEUE_BYTES_PER_INSTANCE` (64 MiB); forwards only with a permit; queued requests keep their deadline; a full queue answers `RESOURCE_EXHAUSTED`. Clients grant `max-concurrent-handlers` permits up front and one per completed handler (at once when few are left at the hub, else batched: 16 or 50 ms). Queued requests are routed again when their instance leaves, taken over when it reconnects; a hub-wide byte cap `SNODRA_SERVER_QUEUE_BYTES_TOTAL` (512 MiB). Topology shows `permitsAvailable` and `queued`. | The sandbox smoke's flow-demo steps run 20 parallel calls into a one-permit, slowed service-b and expect all to succeed. |
| F4 | **Server-side default and maximum timeout alignment** — **done** | Hub: per-type override `SNODRA_SERVER_TIMEOUT_OVERRIDES=type=ms,...`; effective timeout `min(timeout_ms, override or max)` for `timeout_ms > 0`, `override or default` for 0. Clients: send `timeout_ms = 0` unless the caller chose a timeout, guard locally with the ack's per-type or maximum timeout + 1 s. | The 5 s default stays; overrides are for the few long-running types. |
| F5 | **Caller-side retry policy in the starter** — **done** | Both libraries: opt-in `RetryPolicy` (`hub.retry.enabled=false`, 3 attempts, 100 ms doubling to 2 s) per bus and per call (`SendOptions.retry`). Commands retry `HubUnavailable`, `NO_HANDLER`, `RESOURCE_EXHAUSTED` (the handler never ran); queries also `HANDLER_DISCONNECTED`, `TIMEOUT`, `HubConnectionLost`; never a command after `TIMEOUT` or `HubConnectionLost`. Fresh request id per attempt, all attempts within the caller's time budget; waits get ±20 % jitter and a retry starts only with at least `max(initial backoff, 250 ms)` of the budget left after its wait; the classification is one function, reused later by the saga relay. | Splits errors into transient and non-transient; off by default, so the semantics in `02-messaging.md` stay exact. |

Not planned: a multi-minute default timeout and an in-memory command cache sized from JVM
memory. The hub keeps short, caller-chosen deadlines; long work belongs behind an event.


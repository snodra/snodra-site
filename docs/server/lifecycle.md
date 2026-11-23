# Connection lifecycle

Registration, heartbeats, reconnection and the failure modes a client must handle.

- HTTP/2 keepalive PINGs every 10 s, the connection is dropped when a PING is
  not answered within 20 s; TCP keepalive is 30 s. These are constants in `src/lib.rs`.
- A stream that misses heartbeats for `SNODRA_SERVER_HEARTBEAT_TIMEOUT` is evicted: its session is removed, its
  stream task stops at once (even if the client no longer reads), its registration is dropped and
  its in-flight requests fail with `HANDLER_DISCONNECTED`. the watchdog checks
  every tenth of the threshold (10 ms to 1 s), so an eviction lands at most about a
  second after the threshold.
- A `Register` with an instance id that already has a live stream replaces the old stream (logged
  at `info` as `session replaced by a new stream`); the old stream is closed. Requests forwarded
  to the old stream fail at once with `HANDLER_DISCONNECTED` (clients answer only on the stream a
  request arrived on), requests it sent are dropped; the new session's requests are untouched.
- when a sender's buffer is full, a terminal `Reply` or `Error` is retried in
  the background for up to 5 s before it is dropped (logged at `warn`, counted in
  `snodra_server_session_buffer_full_total{service}`).
- Graceful shutdown on SIGTERM or Ctrl-C: health turns `NOT_SERVING`, every stream is closed with
  `UNAVAILABLE` `hub shutting down` (in-flight requests fail as on a disconnect), connections get
  at most 5 s to drain, then telemetry is flushed and the process exits.

## Handshake

```text
client                                   hub
  Register{..., client_version,      -->   registers the instance
           initial_permits}
  Heartbeat{sent_at_ms=t}            -->
                                     <--   RegisterAck{hub_id, heartbeat_interval_ms,
                                                       heartbeat_timeout_ms, default_timeout_ms,
                                                       max_timeout_ms, context, type_timeouts_ms}
                                     <--   Heartbeat{sent_at_ms=t}   (echo)
```

- Every accepted `Register` gets a `RegisterAck`; the first one is queued before the echo of the
  heartbeat that follows the `Register`, because the hub handles a stream's messages in order. The
  ack is the client's confirmation that the `Register` was processed (the ack of a later
  `Register` is dropped, like a heartbeat echo, when the session's outbound buffer is full).
  Requests routed to the new instance meanwhile may arrive before the ack.
- A `Register` the hub refuses closes the stream with a status instead (`INVALID_ARGUMENT`,
  `ALREADY_EXISTS`, `UNAUTHENTICATED`, `PERMISSION_DENIED`); a stream without a `Register` within
  `SNODRA_SERVER_HANDSHAKE_TIMEOUT` is closed with `DEADLINE_EXCEEDED`.
- Every session has every feature: flow control,
  `InstanceStatus` reports ([High availability](operations.md#high-availability)), the query modes
  ([Query modes](protocol.md#query-modes)), credential refresh (`ClientMessage.credentials`;
  [JWT credentials](https://snodra.damoreira.com/server/configuration/jwt-oauth2/)), event processor status (`InstanceStatus.processors`;
  [Event processors](event-processors.md)) and processor control (`ServerMessage.control` and
  `ClientMessage.control_reply`; [Processor control](processor-control.md)). The hub and the client
  libraries ship together: a hub and a client of different builds are not supported.
- `CANCELLED` (9) ends a stream that outlived `SNODRA_SERVER_MAX_STREAM_DURATION` or a subscription
  that outlived `SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION`.

## Timing

The hub echoes a client `Heartbeat` with `sent_at_ms` unchanged.

| Parameter | Value | Where set |
|---|---|---|
| Heartbeat interval | 3 s | hub, `SNODRA_SERVER_HEARTBEAT_INTERVAL`, announced in `RegisterAck.heartbeat_interval_ms` |
| Instance considered dead | 10 s without heartbeat, or stream closed | hub, `SNODRA_SERVER_HEARTBEAT_TIMEOUT`, announced in `RegisterAck.heartbeat_timeout_ms` |
| Eviction check | every tenth of the timeout (10 ms to 1 s) | fixed |
| Client gives up a silent hub | on a heartbeat tick, more than 3 intervals since the last echo and 3 heartbeats unanswered (9 to 12 s); not before the `RegisterAck` | clients |
| Default request timeout | 5 s | hub, for `Request.timeout_ms == 0` without override, `SNODRA_SERVER_DEFAULT_TIMEOUT_MS` |
| Maximum request timeout | 60 s | hub clamps larger client values on types without override, `SNODRA_SERVER_MAX_TIMEOUT_MS` |
| Per-type request timeout | none | `SNODRA_SERVER_TIMEOUT_OVERRIDES=type=ms,...`; replaces both default and clamp for its type |
| Client-side guard | hub's bound for the type (override or maximum) + 1 s | clients |
| Owner grace after last instance leaves | 60 s | `SNODRA_SERVER_OWNER_GRACE` |
| Handshake deadline | 10 s | `SNODRA_SERVER_HANDSHAKE_TIMEOUT`; stream closed with `DEADLINE_EXCEEDED` if no `Register` arrives |
| HTTP/2 keepalive, hub side | ping every 10 s, timeout 20 s; TCP keepalive 30 s | fixed |
| HTTP/2 keepalive, client side | ping every 10 s, timeout 5 s, also while idle | fixed in both client libraries |
| Client reconnect backoff | 500 ms doubling to 5 s, ±20 % jitter (never above the maximum), back to 500 ms once an attempt reached the handshake | clients (`snodra.messaging.hub.reconnect-backoff.*`) |
| Per-session send buffer | 1024 messages | `SNODRA_SERVER_SESSION_BUFFER`; when full, new requests to that instance get `RESOURCE_EXHAUSTED` |
| Per-instance queue | 10 000 requests, 64 MiB | `SNODRA_SERVER_QUEUE_CAPACITY_PER_INSTANCE`, `SNODRA_SERVER_QUEUE_BYTES_PER_INSTANCE`; queued requests keep their own deadline |
| All queues of the hub | 512 MiB | `SNODRA_SERVER_QUEUE_BYTES_TOTAL` |
| Maximum stream duration | 10 min | `SNODRA_SERVER_MAX_STREAM_DURATION`; the stream ends with `CANCELLED` |
| Updates buffered per subscription | 256 | `SNODRA_SERVER_SUBSCRIPTION_BUFFER`; one more ends the subscription with `RESOURCE_EXHAUSTED` |
| Subscription targets per handler instance | 1024 | `SNODRA_SERVER_MAX_SUBSCRIPTIONS_PER_INSTANCE`; a subscription beyond it is refused with `RESOURCE_EXHAUSTED` |
| Maximum subscription duration | none | `SNODRA_SERVER_MAX_SUBSCRIPTION_DURATION` (`0` = unlimited; at least `1s`); the subscription ends with `CANCELLED` |
| Client permit grants | one per completed handler; sent at once while the hub holds `min(16, initial_permits / 2)` or fewer of the instance's permits, else batched at 16 or after 50 ms | clients; a one-permit instance is no longer capped at ~20 requests/s |

Effective request timeout, with `override` the `SNODRA_SERVER_TIMEOUT_OVERRIDES` entry for the type:

| `Request.timeout_ms` | Deadline |
|---|---|
| `> 0` | `min(timeout_ms, override or max)` |
| `0` | `override or default` |

Clients send `timeout_ms = 0` unless the caller chose a timeout, so an override applies to them
without client configuration.

## Failure modes

| Situation | Hub behaviour | Sender sees |
|---|---|---|
| Type never registered | reply immediately | `Error{NO_HANDLER}` |
| Owner service has no live instance but is inside the grace period | reply immediately | `Error{NO_HANDLER}` (message says "owner known, no instance") |
| Handler instance closes stream while request in flight | fail all its pending requests | `Error{HANDLER_DISCONNECTED}` |
| Handler reconnects with the same instance id while its old stream is still registered | the new stream replaces the old session; requests forwarded to the old stream fail at once (clients reply only on the stream a request arrived on) | `Error{HANDLER_DISCONNECTED}` |
| Handler silent for the heartbeat timeout (10 s) | remove instance, fail pending requests | `Error{HANDLER_DISCONNECTED}` |
| No reply before deadline | drop pending entry, ignore late reply | `Error{TIMEOUT}` |
| Sender disconnects before reply | drop pending entry, ignore reply | nothing (sender is gone) |
| Handler returns `Reply{error}` | forward unchanged | `Error` with the handler's code |
| Hub restarts | all streams drop; clients reconnect with backoff (at most 5 s apart) and re-register | requests already written: `HubConnectionLostException` (outcome unknown); requests sent while no stream is up: `HubUnavailableException` (never sent) |
| Request has no kind, no type or no id | reply immediately | `Error{INVALID_REQUEST}` "invalid request: ..." |
| A point query, a stream or a gather of a subscription type (`Register.subscription_query_types`), or a subscription of a query type no registrant declared | reply immediately; no instance gets anything | `Error{INVALID_REQUEST}` naming the type and the mode |
| `Request.id` already in flight | reject the new request, the earlier request is untouched | `Error{INVALID_REQUEST}` "invalid request: duplicate id" |
| Handler instance's outbound buffer full | reply immediately | `Error{RESOURCE_EXHAUSTED}` |
| Handler has no permit | queue the request (priority, then age) | latency; the reply once a permit arrives |
| Queue of the target instance full (count or bytes) | reply immediately | `Error{RESOURCE_EXHAUSTED}` (`HandlerBusyException`) |
| Queued request reaches its deadline | drop it from the queue | `Error{TIMEOUT}` |
| Handler disconnects with requests queued | fail the forwarded requests; route the queued ones again (same id, remaining deadline) | forwarded: `Error{HANDLER_DISCONNECTED}`; queued: answered by another instance, or `Error{NO_HANDLER}` when none is left |
| Handler reconnects (new stream, same instance id) with requests queued | the new session takes over the queue | forwarded: `Error{HANDLER_DISCONNECTED}`; queued: served by the new stream |
| Handler re-registers without types (graceful stop) | no longer a routing target; its queue is routed to the other instances | what it was forwarded it still answers |
| All queues of the hub hold `SNODRA_SERVER_QUEUE_BYTES_TOTAL` | reply immediately | `Error{RESOURCE_EXHAUSTED}` |
| Two services register the same type | second `Register` rejected, stream closed with `ALREADY_EXISTS` | the second service does not fail startup: it keeps reconnecting (at the backoff cap) and none of its handlers is reachable through that hub. Kotlin surfaces the rejection as `HubRegistrationRejectedException` from `awaitRegistered` (`lastRejection` on the connection); Rust keeps retrying with the reason in `last_rejection`; Go with the reason in `App.Rejection` ([The messaging model](../messaging/index.md)) |
| A type registered exclusive by one registrant and shared by another | the later `Register` rejected, stream closed with `ALREADY_EXISTS` | as above: the later registrant keeps reconnecting and exposes the rejection; it does not fail startup |
| A type declared a subscription type by one registrant and not by another (also the type's only instance re-registering it the other way, until the hub forgets the type after the owner grace) | the later `Register` rejected, stream closed with `ALREADY_EXISTS` | as above |
| A type in `subscription_query_types` that is in neither `query_types` nor `shared_query_types` of the same `Register` | stream closed with `INVALID_ARGUMENT` | as above |
| `Register` without credentials, or with an unknown token (`enforce`) | stream closed with `UNAUTHENTICATED`; nothing is registered | the service's connection fails and retries at the backoff cap: a registration rejection (`lastRejection`, `HubRegistrationRejectedException` from `awaitRegistered`, `await_hub` false in Rust, one `ERROR` line; [Client configuration](https://snodra.damoreira.com/server/configuration/mtls/)). `jwt` credentials on a hub with no `SNODRA_SERVER_JWT_ISSUER`: `UNAUTHENTICATED` "jwt credentials are not configured on this hub" |
| `Register` with an invalid JWT (`enforce`): expired, wrong issuer or audience, bad signature, `none`/`HS*`, an ID or refresh token | stream closed with `UNAUTHENTICATED` and a short reason ("token expired", "wrong token issuer", ...), never the token | as above (a registration rejection) |
| `Register` with a JWT for another service (`azp` differs), or for a service with no `[[service]]` table (`enforce`) | stream closed with `PERMISSION_DENIED` "token azp `<a>` is not service `<b>`" or "no ACL entry for service `<a>`" | as above |
| `Register` with a JWT before the first fetch of the signing keys succeeded | stream closed with `UNAVAILABLE` "jwks not loaded yet" | an ordinary stream closure: the client reconnects from the backoff floor |
| `Register` with a JWT whose `kid` is not in the key set and no fetch made for it has looked yet (a key rotation) | stream closed with `UNAVAILABLE` "signing key not known yet"; once a fetch made for it has found it missing: `UNAUTHENTICATED` "unknown signing key" | `UNAVAILABLE`: an ordinary stream closure, the client retries from the backoff floor; `UNAUTHENTICATED`: a registration rejection |
| A JWT session reaches `exp` + `SNODRA_SERVER_JWT_EXPIRY_GRACE` with no successful refresh (`enforce`) | stream closed with `UNAUTHENTICATED` "credentials expired"; pending requests end as on any disconnect. `permissive`: counted (`expired`) and logged once, the session stays. Requests between `exp` and the deadline are still allowed | the service: a registration rejection and a reconnect with a fresh token |
| `Register` over a client certificate that names no service (no `snodra://service/<name>` URI SAN), or several (`enforce`) | stream closed with `PERMISSION_DENIED` "certificate names no service" / "certificate names more than one service" | as above (a registration rejection) |
| `Register` with `credentials` that resolve to another service than the client certificate (`enforce`) | stream closed with `PERMISSION_DENIED` "credentials and certificate name different services"; `permissive` counts it and the certificate wins | as above |
| A client without a valid certificate on a `required` listener, or with an invalid one on an `optional` one | TLS handshake fails (counted `snodra_server_tls_handshake_failures_total{reason="client_cert_missing"\|"client_cert_invalid"}`); no stream exists | a transport failure: the connection is retried at the normal backoff (TLS 1.3: the client sees it when the stream opens) |
| A certificate session reaches `notAfter` (`enforce`) | stream closed with `UNAUTHENTICATED` "certificate expired", no grace; pending requests end as on any disconnect. `permissive`: counted (`expired`) and logged once, the session stays | the service: an ordinary stream closure, not a registration rejection: it reconnects at the normal backoff (`INFO`, no `lastRejection`) with its renewed certificate; it should reload the files and reconnect before `notAfter` |
| `ClientMessage.credentials` that is invalid, or for another service (`enforce`) | stream closed with `UNAUTHENTICATED` / `PERMISSION_DENIED`; `permissive` counts it and keeps the old credential | as above |
| `Register` as a service the token does not grant, or for a type outside its `handle` (`enforce`) | stream closed with `PERMISSION_DENIED`, naming the type | as above (a registration rejection); a later `Register` on a live stream that adds such a type closes that stream |
| `Register` under an instance id held by a live session of another service (`enforce` and `permissive`) | stream closed with `PERMISSION_DENIED` "instance id `<8 chars>` belongs to another service"; the holder is untouched | as above (a registration rejection) |
| A request for a type outside the token's `send` (`enforce`) | answered before anything is routed, in every request mode | `Error{PERMISSION_DENIED}` naming the type (`UNAUTHENTICATED` when the token left the ACL) |
| The ACL file changes so a live session is no longer allowed (`enforce`) | session closed with the matching status; its pending requests end as on any disconnect | the service: `UNAUTHENTICATED` (token removed) or `PERMISSION_DENIED` (service changed, `handle` narrowed); its senders: `Error{HANDLER_DISCONNECTED}` |
| The ACL file or the TLS pair cannot be read or parsed on reload | previous ACL / certificate kept; logged at `error`, `snodra_server_acl_reload_errors_total` for the ACL | nothing |
| The ACL file or the TLS pair is bad at startup | the hub refuses to start | no hub |
| `permissive` mode, any of the above | logged (`warn`) and counted in `snodra_server_auth_violations_total`; allowed | nothing |
| Scatter-gather failures | see [Query modes](protocol.md#query-modes) | `ReplyPart` with an error, `ReplyEnd{timed_out}`, or an `Error` before any target |
| Streaming query failures | see [Query modes](protocol.md#query-modes) | `ReplyEnd{error}` (`TIMEOUT`, `CANCELLED`, `HANDLER_DISCONNECTED`, `INVALID_REQUEST`, capacity, or the handler's own), or an `Error` before the target |
| Subscription failures | see [Query modes](protocol.md#query-modes) | `ReplyEnd{error}` (the initial request's `TIMEOUT`, `HANDLER_DISCONNECTED` or capacity error, a target's own, `RESOURCE_EXHAUSTED` for a full subscriber buffer, `HANDLER_DISCONNECTED` when the last target left, `CANCELLED` for the max duration), or an `Error` before any target (`RESOURCE_EXHAUSTED` for the per-instance limit) |

The hub itself produces `NO_HANDLER`, `TIMEOUT`, `HANDLER_DISCONNECTED` and `INVALID_REQUEST`
(malformed or duplicate requests, an unknown request mode, a part without credit),
`RESOURCE_EXHAUSTED` (full queues and buffers, the subscription limits) and `CANCELLED` to the
sender of a stream or subscription that outlived its maximum duration; with access control,
`UNAUTHENTICATED` and `PERMISSION_DENIED` for a request it refuses.

Nothing is retried by the hub. Retry policy belongs to the sender and is described in
[The messaging model](../messaging/index.md).

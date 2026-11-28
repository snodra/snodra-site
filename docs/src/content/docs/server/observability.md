---
title: "Observability"
---

Traces, metrics, logs and the health endpoint.

## Implementation notes

- Traces: one span `hub.route` per request, with the outcome in `snodra.outcome`; parent context
  is taken from the request's trace headers. Exported over OTLP.
- Dashboard: `http://localhost:7001/` for a live view of services, types and traffic (see
  [Dashboard](/docs/server/dashboard/)); Grafana for history.
- Metrics (OTLP): `snodra_server_auth_violations_total{reason,service}`, `snodra_server_acl_generation`,
  `snodra_server_acl_reload_errors_total`, `snodra_server_jwt_validations_total{result}`,
  `snodra_server_jwks_fetches_total{result}` (`ok`, `network`, `tls`, `timeout`, `status`, `too_large`, `invalid`), `snodra_server_jwks_keys`,
  `snodra_server_credentials_refreshes_total{result}`, `snodra_server_client_certificates_total{result}`,
  `snodra_server_tls_handshake_failures_total{listener,reason}`, `snodra_server_tls_client_ca_reload_errors_total`, `snodra_server_requests_total` (outcome `denied` for a refused request), `snodra_server_request_duration_seconds`,
  `snodra_server_in_flight` (queued requests included), `snodra_server_connected_instances`, `snodra_server_registered_types`,
  `snodra_server_session_buffer_full_total`, `snodra_server_register_refused_total{reason}`, and for flow control `snodra_server_queue_depth{service}`,
  `snodra_server_permits_available{service}`, `snodra_server_queue_wait_seconds{service,type}`,
  `snodra_server_rejected_total{service,reason}` (`queue_full`, `queue_bytes`, `queue_bytes_total`,
  `buffer_full`), `snodra_server_scatter_targets{type}` (targets per scatter-gather),
  `snodra_server_streams_open{service,instance_id}` (streaming queries open per handler instance) and
  `snodra_server_stream_parts_total{service,type}` (parts relayed),
  `snodra_server_subscriptions_open{service,instance_id}` (subscription targets open per handler
  instance; with `streams_open` the only metrics with an instance label) and
  `snodra_server_subscription_updates_total{service,type}` (updates relayed), `snodra_server_control_total{action,outcome}`
  (processor control calls), `snodra_server_control_unknown_replies_total` (control replies nobody waited for), and for
  the [event browser](/docs/server/event-browser/) `snodra_server_event_browser_requests_total{kind,outcome}`,
  `snodra_server_event_browser_scanned_records`, `snodra_server_event_tails` and `snodra_server_event_payload_views_total`
  (what the server sees of the events API; the subscription lag is the add-on's own `snodra_event_browser_subscription_lag`). Queue depth and
  permits are refreshed by the watchdog every tick (at most a second), not per request.
- Health: the standard `grpc.health.v1.Health` service on the same port (service
  `snodra.hub.v1.Hub`, and `""` for the whole server). `snodra-server --health-check` probes it on
  `127.0.0.1:<port of SNODRA_SERVER_LISTEN>` within 3 s, prints one line and exits 0 when
  `SERVING`, 1 otherwise.
- Logs: JSON on stdout, filtered by `SNODRA_SERVER_LOG`.

## Observability

Traces: the hub starts a span `hub.route` per request, parented from `headers.traceparent`, with
attributes `snodra.type`, `snodra.kind`, `snodra.sender`, `snodra.handler`, `snodra.outcome`. The `hub.route`
span is parented on the request's `traceparent`. The
forwarded `Request` keeps the original `traceparent` so the handler's span is a child of the sender's,
not of the hub's.

Metrics: OTLP to `SNODRA_SERVER_OTLP_ENDPOINT` (every 60 s, the SDK's default; `OTEL_METRIC_EXPORT_INTERVAL` in ms
changes it), named below as Prometheus stores them. The resource
is `service.name=snodra-server` and `service.instance.id=<SNODRA_SERVER_ID>`, so every series carries `job="snodra-server"` and
`instance="<hub id>"` (otel-lgtm also adds `service_name` and `service_instance_id` with the same values); no data
point carries a hub id. Labels below are the data-point labels only. `service` is always the handling side (the
service a request was routed to, whose queue, permits, streams or processors are counted); a `type` is a registered
command or query type.

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `snodra_server_requests_total` | counter | `kind`, `type` (`other` for a request answered before routing, as `no_handler`, `denied` or `invalid_request`, whose type has no owner: what a sender names is not bounded), `mode` (`unary`, `scatter_gather`, `streaming`, `subscription`, `unknown` for a mode the protocol does not define), `service` (the handling service; absent when no handler was found or a gather's or subscription's targets span services), `outcome` (`ok`, `no_handler`, `timeout`, `handler_disconnected`, `handler_error`, `invalid_request`, `resource_exhausted`, `cancelled`, `denied`) | requests routed. Any handler `Reply{error}`, `ReplyPart.error` or `ReplyEnd.error` counts as `handler_error`; a capacity rejection as `resource_exhausted`; a scatter-gather counts once (`ok` when any part succeeded, else `timeout` when a target timed out, else its last failed part's outcome); a stream once at its end (`cancelled` for a sender's cancel or the max duration); a subscription once at its initial part (or at an ending before it) |
| `snodra_server_request_duration_seconds` | histogram | `kind`, `type` (`other` as above), `mode`, `service` (as above); never the outcome | time from request receipt to its terminal message: a gather's or stream's to its `ReplyEnd`, a subscription's to its initial part, so `mode` keeps them apart from the unary latency of the type. Buckets 1 ms to 60 s |
| `snodra_server_in_flight` | gauge | `kind` | requests awaiting a reply; requests waiting in a queue count |
| `snodra_server_connected_instances` | gauge | `service` | instances with a stream to this hub (one session each); 0 once after a service's last instance left |
| `snodra_server_registered_types` | gauge | `service`, `kind` | message types the service's instances registered |
| `snodra_server_session_buffer_full_total` | counter | `service` | messages not delivered because a session buffer was full |
| `snodra_server_register_refused_total` | counter | `reason` (`missing_contract`, `unknown_contract`, `duplicate_contract`, `disagreeing_contract`, `invalid_schema`, `invalid_contract`, `schema_conflict`, `invalid_types`, `type_conflict`, `invalid_register`) | `Register` messages refused for a reason other than access control (that is `snodra_server_auth_violations_total`); a fixed label set, never text a client chose. The contract reasons are those of the [schema catalogue](/docs/server/catalog/): `missing_contract` (a handled type without a contract), `unknown_contract` (a contract for a type the `Register` does not declare), `duplicate_contract`, `disagreeing_contract` (kind, shared or subscription flag), `invalid_schema` (over the size or depth limit, not JSON, not an object), `invalid_contract` (an unspecified kind, an event contract with no type) and `schema_conflict` (a live contract with a different schema). `invalid_types` and `type_conflict` are the type-list refusals (a type listed twice or as shared and exclusive; a type another service owns, or a kind, sharing or subscription flag the owner registered differently); `invalid_register` is an empty service name or instance id, a reserved name, or no permits |
| `snodra_server_queue_depth` | gauge | `service`, `type` | requests queued for the service's instances; 0 once after a queue of that type emptied |
| `snodra_server_permits_available` | gauge | `service` | flow-control permits the service's instances have left on this hub |
| `snodra_server_queue_wait_seconds` | histogram | `service`, `type` | time a request waited in a queue before it was forwarded |
| `snodra_server_rejected_total` | counter | `service`, `reason` (`queue_full`, `queue_bytes`, `queue_bytes_total`, `buffer_full`) | requests rejected for capacity |
| `snodra_server_scatter_targets` | histogram | `type` | targets of one scatter-gather query |
| `snodra_server_streams_open` | gauge | `service`, `instance_id` (the handler's) | streaming queries open, per handler instance with one open; an instance whose last one closed reads 0 once, then has no series (observed at export) |
| `snodra_server_stream_parts_total` | counter | `service` (the handler's), `type` | parts of streaming queries relayed |
| `snodra_server_subscriptions_open` | gauge | `service`, `instance_id` (the handler's) | subscription targets open (one subscription over three instances counts 3), per handler instance with one open; an instance whose last one closed reads 0 once, then has no series |
| `snodra_server_subscription_updates_total` | counter | `service` (the target's), `type` | updates of subscription queries relayed |
| `snodra_server_processor_lag` | gauge | `service`, `processor` | records behind: the sum over the processor's distinct segments of the lag the freshest report gives each (as the [Processors page](/docs/server/event-processors/)); absent while no lag is known |
| `snodra_server_processor_dead_letters` | gauge | `service`, `processor` | dead letters, the highest count its instances report (each samples the service-wide count) |
| `snodra_server_processor_state` | gauge | `service`, `processor`, `state` (`starting`, `running`, `failing`, `stopped`, `paused`, `unspecified`) | 1 for the processor's state (the worst over its instances), 0 for the others |
| `snodra_server_processor_processed` | gauge | `service`, `processor` | records processed, summed over the instances that report the processor, each since its own start; drops when an instance restarts, so not a counter (rates: the libraries' `snodra_events_consumed_total`) |
| `snodra_server_processor_failed` | gauge | `service`, `processor` | records whose handling failed, summed the same way |
| `snodra_server_auth_violations_total` | counter | `reason` (`no_credentials`, `unknown_token`, `jwt_not_configured`, `jwt_invalid`, `jwks_unavailable`, `cert_no_service`, `cert_multiple_services`, `cert_mismatch`, `wrong_service`, `no_acl_entry`, `handle_denied`, `send_denied`, `token_revoked`, `expired`, `instance_takeover`, `topology_unauthenticated`, `catalog_unauthenticated`), `service` (a name the ACL holds, else `unknown`) | access-control violations, refused in `enforce` or only allowed in `permissive` |
| `snodra_server_acl_generation` | gauge | none | 1 at startup, plus one per reload that changed the ACL |
| `snodra_server_acl_reload_errors_total` | counter | none | reloads that failed to read or parse (the previous ACL stays) |
| `snodra_server_jwt_validations_total` | counter | `result`: `ok`, or why not: `expired`, `not_yet_valid`, `bad_signature`, `bad_alg`, `unknown_kid`, `key_pending` (the `kid` is not known and no fetch made for it has looked yet), `wrong_issuer`, `wrong_audience`, `wrong_type`, `missing_claim`, `malformed`, `not_loaded` | one per JWT checked (a `Register`, a refresh, a `Topology` call); never a client-chosen string |
| `snodra_server_jwks_fetches_total` | counter | `result`: `ok`, `network`, `tls` (the certificate is not trusted or does not match, or the peer does not speak TLS), `timeout`, `status`, `too_large`, `invalid` | signing-key set fetches; a failed fetch keeps the last good key set, and its one `warn` line per streak names the cause (the rustls or I/O error, the HTTP status code) |
| `snodra_server_jwks_keys` | gauge | none | signing keys in the loaded set, absent until the first successful fetch |
| `snodra_server_credentials_refreshes_total` | counter | `result`: `ok`, `refused`, `wrong_service` (valid but for another service), `throttled` (less than a second after the previous one), `unavailable` (the hub could not judge it yet: key set not loaded, or the `kid` not known; the session keeps its old credentials), `ignored_certificate_session` (the session is authenticated by its client certificate, which no message replaces) | `ClientMessage.credentials` handled |
| `snodra_server_client_certificates_total` | counter | `result`: `ok`, `no_service` (no `snodra://service/<name>` URI SAN, a name outside `[A-Za-z0-9._-]{1,128}`, or a certificate that does not parse), `multiple_services`, `mismatch` (`Register.credentials` name another service), `expired` (ended at `Register`, or the session reached `notAfter`) | one per `Register` that carried a certificate, plus one per expiry; never a client-chosen string |
| `snodra_server_tls_handshake_failures_total` | counter | `listener`, `reason`: `client_cert_missing` (a required client certificate was not presented), `client_cert_invalid` (it did not verify against the client CA, or had ended), `timeout`, `other` (plain text, scans, protocol errors) | TLS handshakes that failed |
| `snodra_server_tls_client_ca_reload_errors_total` | counter | none | client CA bundle reloads that failed (the previous CAs stay) |
| `snodra_server_tls_handshakes_shed_total` | counter | `listener` (`grpc`, `http`), `reason` (`slots`: every handshake slot busy; `per_ip`: the peer IP is at `SNODRA_SERVER_TLS_HANDSHAKES_PER_IP`) | connections dropped without a handshake |
| `snodra_server_control_total` | counter | `action` (`pause`, `resume`, `reset`, `dead_letter_list`, `dead_letter_retry`, `dead_letter_retry_all`, `dead_letter_discard`), `outcome` (`ok`, `bad_request`, `not_found`, `conflict`, `failed`, `timeout`, `unavailable`, and for a refused credential `unauthenticated`, `forbidden`, `disabled`) | one per [processor control](/docs/server/processor-control/) call |
| `snodra_server_control_unknown_replies_total` | counter | none | `ControlReply` messages dropped because no request waits for them (an unknown id, a reply after the timeout, or one from another session than the one asked) |
| `snodra_server_event_browser_requests_total` | counter | `kind` (`search`, `record`, `sources`, `lag`, `tail`), `outcome` (`ok`, `bad_request`, `forbidden`, `not_found`, `too_many`, `unavailable`, `not_installed`, `timeout`, `failed`) | one per call of the [events API](/docs/server/event-browser/) (`not_installed` while no event browser is connected) |
| `snodra_server_event_browser_scanned_records` | histogram | none | records one event search read, as the event browser reports it |
| `snodra_server_event_tails` | gauge | none | event tails open on this hub now |
| `snodra_server_event_payload_views_total` | counter | none | event payloads served by the record detail (each also writes an audit line) |

`snodra_server_streams_open` and `snodra_server_subscriptions_open` are the metrics with a per-instance label (streams and
subscriptions are long-lived and pin their instances); no other metric has one. The label is `instance_id`, never
`instance`, which Prometheus overwrites with the hub id. `snodra_server_connected_instances`,
`snodra_server_registered_types`, `snodra_server_queue_depth` and `snodra_server_permits_available` are refreshed by the
watchdog every tick (at most a second), not per request. The processor gauges are observed when the metrics are
exported, from the latest `InstanceStatus` of every session. A processor nobody reports any more is exported once
more as 0, then not at all.

**No event store on the server.** The server reads no event store and exports no consumer-group lag. The events
API metrics above count the calls the server routes to the [`snodra-event-browser` add-on](/docs/tools/event-browser/);
the add-on exports the subscription lag itself, as `snodra_event_browser_subscription_lag{subscription,source}`
(and `snodra_event_browser_lag_refreshes_total{outcome}`), from its own process.

**Several hubs.** Every series carries its hub as `instance`. Counters, histograms and the hub-local gauges
(`queue_depth`, `permits_available`, `in_flight`, `streams_open`, `subscriptions_open`) add up over hubs (`sum`);
`connected_instances`, `registered_types` and the processor gauges are the same on every hub
(every instance registers and reports to every hub), so they combine with `max`:
`max by (service, processor) (snodra_server_processor_lag)`, `max by (service) (snodra_server_connected_instances)`,
`sum by (service, type) (rate(snodra_server_requests_total[5m]))`.

Live view: the [dashboard](/docs/server/dashboard/) on port 7001 shows the current topology and the last five
minutes of traffic per sender and type; Grafana keeps the history of the metrics above.

Logs: structured JSON via `tracing-subscriber`, one line per connect, register and disconnect. The
startup line is `hub listening` (with `tls`), followed by `auth mode`. Access-control lines are
`warn`: `register refused`, `stream closed`, `session closed`, `request refused`, `auth violation
(permissive, ...)`, with `reason`, `service` and `key` (the first 8 hex characters of the token's
digest, `-` without one); never a token, a digest beyond that prefix, or a credential. There is one `warn` line per hub-produced error outcome and one
`info` line per relayed handler error. Every [processor control](/docs/server/processor-control/) call that passed the credential
check writes one `info` audit line, message `control`, with `caller` (`write-token`, the ACL service name, or for a
read `dashboard-token`, `write-token` or `anonymous`), `service`, `processor`, `action`, `outcome`, `duration_ms` and
`operation_id` (a reset's, `-` otherwise). Every event payload the [event browser](/docs/server/event-browser/) serves writes one
`info` line `event payload served` with `caller` (`dashboard-token` or `write-token`), `source`, `segment`, `position`,
`size` and `correlation_id`; a payload search writes `event payload search` with `caller`, `source`, `tail` and
`correlation_id`, never the searched text. Payload bytes are never logged.

Health: gRPC health service (`grpc.health.v1.Health`) on the same port, used by the compose
healthcheck and by Kubernetes probes. The distroless image has no shell, so the binary has a
`--health-check` mode: it calls `grpc.health.v1.Health/Check` on its own listen port and exits 0
when the status is `SERVING`. Compose and the Dockerfile `HEALTHCHECK` use
`["CMD", "/app/snodra-server", "--health-check"]`. With TLS configured in the container's environment
the probe speaks TLS too and pins the hub's own certificate ([TLS](https://snodra.damoreira.com/docs/server/configuration/mtls/)); no change to the
`HEALTHCHECK` is needed.

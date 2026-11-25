---
title: "Monitoring"
---

Snodra exports OpenTelemetry metrics and traces over OTLP, and serves a live dashboard. This page is
the short operator's map; the exhaustive metric tables are in
[Observability](/docs/server/observability/).

## Three sources

| Source | Prefix | What it tells you |
|---|---|---|
| Server | `snodra_server_*` | Requests, latency, queues, permits, connected instances, processor status, auth failures, events API calls |
| Client libraries | `snodra_*` | Outbox, consumed events, processor lag and state, dead letters, sagas, hub-client latency |
| Event browser | `snodra_event_browser_*` | Subscription lag and refresh outcomes (when it runs as its own service) |

Every series carries `job` (the service name) and `instance` (the instance id). The server uses
`service.name=snodra-server`; a library uses its configured service name.

## Turn it on

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT=http://otel-lgtm:4317 \
  snodra/snodra-server:0.6.0
```

An empty endpoint disables export. The Rust library records through the OpenTelemetry API only: the
application installs the meter provider before the builder runs. The Kotlin starter uses Micrometer,
so the service's normal Actuator/OTLP setup applies. The Go library records through its optional
`observability` module (`github.com/snodra/snodra-messaging-go/observability`), on the OpenTelemetry API only: the
application installs the SDK and passes `snodra.Telemetry(observability.New())`. The Python library records through
its optional `snodra-messaging-observability` package (`snodra_observability.Observability`), on the OpenTelemetry
API only: the application installs the SDK and passes `telemetry=Observability()`. Set `OTEL_METRIC_EXPORT_INTERVAL`
(milliseconds) to change the 60-second default.

## The four signals to alert on

| Signal | Metric | Why |
|---|---|---|
| Capacity | `snodra_server_rejected_total{reason}` | Requests are being refused because a queue or buffer is full |
| Latency | `snodra_server_queue_wait_seconds` | Time spent waiting for a permit, before the handler even starts |
| Backlog | `snodra_outbox_pending`, `snodra_outbox_oldest_age_seconds` | Events are committed but not reaching the event store |
| Consumption | `snodra_processor_lag`, `snodra_dead_letters` | A processor is falling behind or parking records |

Two more are worth a page: `snodra_server_auth_violations_total` during an access-control rollout, and
`snodra_processor_state` for a processor stuck in `FAILING` or `PAUSED`.

## Gauges need staleness handling

An instance that stops exports nothing more, and Prometheus keeps the last gauge value. Read library
gauges as `last_over_time(<gauge>[$instance_seen])`, as the shipped dashboards do, so a dead pod
drops out instead of looking connected forever.

## Dashboard and history

The server's dashboard ([http://localhost:7001/ui/](http://localhost:7001/ui/)) shows the live topology, per-edge traffic, queue
depth, permits, processors and dead letters. Set `SNODRA_SERVER_GRAFANA_URL` to link it to Grafana,
which keeps the history. `SNODRA_SERVER_PEERS` merges several servers' dashboards and flags where
their registries disagree.

## Health and logs

The gRPC health service answers on the server's own port; the distroless image probes it with
`/app/snodra-server --health-check`. Logs are JSON on stdout, filtered by `SNODRA_SERVER_LOG`. See
[Observability](/docs/server/observability/) for the log events, audit lines and the full metric
reference, and [Containers](/docs/integrations/containers/) for probes.

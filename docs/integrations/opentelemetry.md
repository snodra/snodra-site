# OpenTelemetry

The server and both libraries export OpenTelemetry metrics and traces. Point them at your collector
and the same series feed the Snodra dashboards and your own.

## Server

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT=http://otel-collector:4317 \
  snodra/snodra-server:0.5.0
```

- **Traces**: one `hub.route` span per request, parented from the request's `traceparent`. The
  forwarded request keeps the original context, so the handler's span is a child of the sender's, not
  of the server's. Attributes name the type, kind, sender, handler and outcome.
- **Metrics**: OTLP gRPC every 60 seconds by default; `OTEL_METRIC_EXPORT_INTERVAL` (milliseconds)
  changes it. The resource is `service.name=snodra-server` and
  `service.instance.id=<SNODRA_SERVER_ID>`, which becomes `job` and `instance` in Prometheus.
- **No traces or metrics endpoint on the server itself.** It pushes; your collector receives.

An empty `SNODRA_SERVER_OTLP_ENDPOINT` disables export, which is what the local quick-start commands
do.

## Libraries

The Rust library records through the OpenTelemetry API and installs nothing itself. Install the SDK
and a meter provider before building the app, with `service.name` set to the Snodra service name and
`service.instance.id` to the instance id the server sees:

```rust
let provider = SdkMeterProvider::builder()
    .with_resource(
        Resource::builder_empty()
            .with_service_name(config.service_name.clone())
            .with_attribute(KeyValue::new("service.instance.id", config.instance_id.clone()))
            .build(),
    )
    .with_periodic_exporter(MetricExporter::builder().with_tonic().with_endpoint("http://otel-collector:4317").build()?)
    .build();
opentelemetry::global::set_meter_provider(provider.clone());
```

The Kotlin starter uses Micrometer, so the service's normal Actuator and OTLP configuration applies.
Both libraries export the same instrument names, so one dashboard works for either.

## Signal names

| Prefix | Owner |
|---|---|
| `snodra_hub_*` | the server |
| `snodra_*` | the client library: outbox, processors, sagas, hub client |
| `snodra_event_browser_*` | the event browser service |

Dots in instrument names become underscores in Prometheus, and counters gain `_total`. Gauges from a
stopped instance need `last_over_time(...)`; the shipped dashboards do that.

## Dashboards

Set `SNODRA_SERVER_GRAFANA_URL` and the dashboard links to Grafana. The server's own dashboard stays
the live view; Grafana keeps history and the cross-service views. The queries and the full metric
reference are in [Observability](../server/observability.md), and the signals worth alerting on are
in [Monitoring](../operations/monitoring.md).

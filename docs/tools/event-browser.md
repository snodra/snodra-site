# Event browser

The event browser searches events, shows one record, tails new ones and lists consumer-group lag
without a Kafka client. It is what the dashboard's **Events** page and the `/api/v1/events*` routes
answer.

## Ways to run it

**In the server.** Set `SNODRA_SERVER_KAFKA_BOOTSTRAP` and the server reads the topics in
`SNODRA_SERVER_EVENT_TOPICS` itself. The routes, their bounds and the payload rules are in
[the server's event browser page](../server/event-browser.md). This is the quickest setup: one
process, one port, the dashboard already there.

**As its own service.** The `snodra-event-browser` image connects to the server like any service and
registers the reserved `snodra.events.*` query types. Use it when the browser should be separate from
the server — for example, when the server should not hold broker credentials, or when several
servers share one browser. In that deployment, without a connected browser the server's events
routes answer 404 `event browser not installed`.

```yaml
services:
  snodra-event-browser:
    image: snodra-event-browser:0.5.0
    environment:
      SNODRA_SERVER_ADDRESS: static://snodra-server:7000
      SNODRA_KAFKA_BOOTSTRAP: kafka:19092
      SNODRA_EVENT_BROWSER_SOURCES: kraken.events
      SNODRA_OTLP_ENDPOINT: http://otel-lgtm:4317
    stop_grace_period: 30s
    depends_on:
      snodra-server:
        condition: service_healthy
```

## What it shows

| View | Question |
|---|---|
| Search | Which events match a type, key, source, time range, correlation id or payload text? |
| Record | What exactly does this topic/partition/offset contain, headers and payload? |
| Tail | What is arriving now? |
| Consumer groups | How far behind is each group on this topic? |
| Lag metric | `snodra_event_browser_subscription_lag{subscription, source}` |

Search reads partitions backwards within a scan budget and a time budget; a page carries a cursor,
so no record is skipped or repeated between pages. Records written after the first page do not appear
in later pages.

## Settings

The server-side settings are `SNODRA_SERVER_EVENT_*` and `SNODRA_SERVER_KAFKA_BOOTSTRAP`; see
[Server settings](../server/configuration/server.md). The standalone service uses its own names:

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_EVENT_STORE` | `kafka` | The store to read |
| `SNODRA_EVENT_BROWSER_SOURCES` | `kraken.events` | Comma-separated sources; the first is the default |
| `SNODRA_EVENT_BROWSER_MAX_SCANNED` | `50000` | Records one search reads at most |
| `SNODRA_EVENT_BROWSER_MAX_RESULTS` | `100` | Results one page returns at most |
| `SNODRA_EVENT_BROWSER_TIMEOUT_MS` | `10000` | Time budget of one call |
| `SNODRA_EVENT_BROWSER_MAX_SEARCHES` | `4` | Searches and listings at once |
| `SNODRA_EVENT_BROWSER_MAX_TAILS` | `4` | Tails open at once |
| `SNODRA_EVENT_BROWSER_TAIL_DURATION_MS` | `900000` | A tail's longest duration |
| `SNODRA_EVENT_BROWSER_MAX_PAYLOAD_BYTES` | `262144` | Payload bytes one record carries |
| `SNODRA_KAFKA_BOOTSTRAP` | `kafka:19092` | The brokers |

Under access control, the ACL entry needs the event-browser right, for example
`event-browser = true` on the service's `[[service]]` table. Without it the browser cannot register
the `snodra.events.*` types.

## Security

Payloads follow the server's payload rules: a record detail serves a payload only to a request that
presents the dashboard or write token, and every payload view writes an audit line. Payload search
(`q`) is refused otherwise. Treat the tokens as read access to your event data.

## Read next

- Routes and payload rules: [Event browser (server)](../server/event-browser.md).
- The dashboard around it: [Dashboard](../server/dashboard.md).
- Processor lag and control: [Event processors](../server/event-processors.md) and
  [Processor control](../server/processor-control.md).

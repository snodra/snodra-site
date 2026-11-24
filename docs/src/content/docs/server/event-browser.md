---
title: "Event browser"
---

Search, inspect and tail events, and read subscription lag, from the dashboard and its HTTP API.

## Event browser

The server reads no event store. The event browser is a separate service, the
[`snodra-event-browser` add-on](/docs/tools/event-browser/): it connects to the hub like any service,
registers the reserved query types `snodra.events.Search`, `Get`, `Sources`, `Lag` and `Tail`, and answers
them from the event store it reads. The hub turns each `/api/v1/events*` call into one of those queries and
serves the answer. The add-on's own settings (event store, sources, scan and time budgets, calls at once, tail
duration and buffer, payload size) are on [its page](/docs/tools/event-browser/#settings); this page is the
hub's side.

- **Optional.** While no browser is connected (no live instance handles `snodra.events.Search`), every route
  below answers 404 `{"error":"event browser not installed"}` and the dashboard hides its Events page.
  Startup, readiness and routing never depend on a browser.
- **Routed like any request.** Each call is a hub-originated request sent as the service `snodra-server`,
  through the router as a client's would be: the browser's permits and queue, the timeouts, the stream credits
  and cancellation all apply. The hub asks a point query with a 30 s timeout, clamped like any client's
  (`SNODRA_SERVER_MAX_TIMEOUT_MS`, `SNODRA_SERVER_TIMEOUT_OVERRIDES`), and gives a search a time budget 2 s
  shorter, so the browser answers what it found before the hub stops waiting. The request carries the
  `correlationId` (the caller's `X-Correlation-Id` when it is 1 to 128 visible ASCII characters, else a fresh
  one; every answer carries it back in `X-Correlation-Id`) and, when the caller presented the dashboard or
  write token, `userId` `dashboard-token` or `write-token`. The hub never forwards a credential.
- **The answers are untrusted.** The hub reads at most 2 MiB of a point query's answer and 64 KiB of a tail
  part, parses them into its own types (what it does not know is dropped, malformed JSON is a 502), keeps only
  the library headers in a summary and drops a payload it did not ask for.
- **Reserved types.** Under access control only a service whose ACL entry has `event-browser = true` may
  register a `snodra.events.*` type; `handle` never grants them, and a `send` pattern grants them only when it
  names the namespace (`snodra.events.*`) or the type: `*` and `snodra.*` do not.
- **Bounded on the hub.** At most `SNODRA_SERVER_EVENT_MAX_TAILS` tails (4, 1 to 1024) are open on this hub;
  one more is 429 with `Retry-After: 1`. Searches, records and listings are bounded by the browser.
- **Access.** The dashboard API's rules: the dashboard token reads (or the write token), CORS for the peers,
  gone with `SNODRA_SERVER_DASHBOARD_ENABLED=false`. Payloads have rules of their own, below.
- **Settings the hub no longer reads.** `SNODRA_SERVER_KAFKA_BOOTSTRAP`, `SNODRA_SERVER_EVENT_TOPICS`,
  `SNODRA_SERVER_EVENT_SEARCH_MAX_SCANNED`, `SNODRA_SERVER_EVENT_SEARCH_MAX_RESULTS`,
  `SNODRA_SERVER_EVENT_SEARCH_TIMEOUT`, `SNODRA_SERVER_EVENT_MAX_SEARCHES`, `SNODRA_SERVER_EVENT_TAIL_DURATION`
  and `SNODRA_SERVER_GROUP_LAG_INTERVAL` belonged to an earlier hub that read Kafka itself. Each one still set
  is a startup warning and is otherwise ignored; set the add-on's settings instead.

### Routes

| Route | Query | Answer |
|---|---|---|
| `GET /api/v1/events` | `snodra.events.Search` | one page of a search, newest first |
| `GET /api/v1/events/{source}/{segment}/{position}` | `snodra.events.Get` | one record with every header, and its payload or why it is hidden |
| `GET /api/v1/events/tail` | `snodra.events.Tail` | server-sent events from the head of every segment |
| `GET /api/v1/events/sources` | `snodra.events.Sources` | the sources the browser reads, its default first, with each segment's bounds |
| `GET /api/v1/events/lag` | `snodra.events.Lag` | every subscription with a committed position on a source, with its lag |

A **source** is what the event store keeps events in (a Kafka topic), a **segment** a part of it (a partition)
and a **position** a place in a segment (an offset); segments and positions are the store's opaque strings, at
most 128 bytes. `source` (search, tail, lag) defaults to the browser's first source; one the browser does not
read is 400. A source the browser reads that does not exist is `"missing": true` with nothing in it.

How a refused call answers:

| Cause | Status |
|---|---|
| no browser connected | 404 `event browser not installed` |
| a parameter the hub or the browser cannot take | 400 |
| `q` without the payload rules | 403, see [Payloads](#payloads) |
| a record, segment or source that does not exist | 404 |
| too many calls at once (the browser's bound, its queue, or this hub's tails) | 429, `Retry-After: 1` |
| the event store did not answer the browser | 503 |
| the browser did not answer in time | 504 |
| anything else (the browser left, or answered something the hub cannot read) | 502 `the event browser failed to answer` |

**Search** parameters, every one optional (an empty value is no filter):

| Parameter | Matches |
|---|---|
| `source` | the source to search |
| `from`, `to` | the record timestamp, inclusive; epoch ms or RFC 3339 (`2026-11-05T10:00:00Z`, `...+01:00`); `from` after `to` is 400 |
| `type` | header `type`, exact; a trailing `*` makes it a prefix (`orders.*`) |
| `key` | the record key, exact, as a summary shows it |
| `service` | header `source` (the publishing service), exact |
| `correlationId`, `userId`, `eventId` | header `correlationId`, `userId`, `id`, exact |
| `q` | a substring of the payload; only where payloads may be served to this request, else 403 |
| `limit` | results per page, a positive number up to the browser's maximum, default 50 |
| `cursor` | continues the search it came from (same source and filters, else 400) |

Each filter is at most 1 KiB and a cursor at most 64 KiB (400 beyond). A page ends at `limit` results
(`stoppedBy: "limit"`), at the browser's scan budget (`"scanBudget"`) or its time budget (`"timeBudget"`), or when
every segment was read to its start (`exhausted: true`, `stoppedBy` and `cursor` null). The cursor holds where each
segment goes on: no record is skipped or repeated between pages, and records written after the first page are not
in later ones.

```bash
H="Authorization: Bearer $SNODRA_SERVER_DASHBOARD_TOKEN"
curl -s -H "$H" 'http://localhost:7001/api/v1/events?type=orders.*&from=2026-11-05T09:00:00Z&limit=2'
```

```json
{
  "source": "snodra.events",
  "results": [
    {
      "source": "snodra.events", "segment": "3", "position": "1841", "timestamp": 1793871062114,
      "key": "order-42",
      "headers": {
        "type": "orders.OrderShipped", "id": "0193e6f0-...", "correlationId": "c-7f1e...",
        "timestamp": "2026-11-05T09:51:02.114Z", "source": "service-b", "userId": "u-17",
        "traceparent": "00-4bf9...-01"
      },
      "size": 212
    },
    { "source": "snodra.events", "segment": "0", "position": "977", "timestamp": 1793871060020,
      "key": "order-42", "headers": { "type": "orders.OrderPlaced", "id": "0193e6ef-...", "source": "service-a" },
      "size": 388 }
  ],
  "scanned": 1500,
  "exhausted": false,
  "stoppedBy": "limit",
  "cursor": "eyJmIjoiOWE0YjJkMGUxZjNjNzE4OCIsInAiOltbMCw5NzddLFsxLDYyMF1dfQ"
}
```

A result is a **summary**, never a payload: where the record is, its timestamp (`null` without one), its key
(`null` without one; at most 128 bytes, `keyTruncated: true` when cut; a byte that is not UTF-8 shows as `\xNN`),
the library headers it carries (`type`, `id`, `correlationId`, `timestamp`, `source`, `userId`, `traceparent`, at
most 256 bytes each) and the payload's size in bytes. The next page: the same query plus `&cursor=<cursor>`.

**Record**: `GET /api/v1/events/snodra.events/3/1841` answers the summary plus `allHeaders` (every header in record
order, at most 64, `headersOmitted` counts the rest: `name` at most 128 bytes, `value` at most 1 KiB, or `valueHex`
when the value is not UTF-8, `truncated` when cut) and the payload:

```json
{
  "source": "snodra.events", "segment": "3", "position": "1841", "timestamp": 1793871062114, "key": "order-42",
  "headers": { "type": "orders.OrderShipped", "id": "0193e6f0-...", "source": "service-b" },
  "size": 212,
  "allHeaders": [
    { "name": "type", "value": "orders.OrderShipped" },
    { "name": "id", "value": "0193e6f0-..." },
    { "name": "x-binary", "value": null, "valueHex": "00ff" }
  ],
  "payload": "{\"orderId\":\"42\",\"carrier\":\"dhl\"}"
}
```

`payload` is the UTF-8 text (cut at the browser's payload limit, 256 KiB by default; pretty-printing is the page's
job), `null` for a record without a payload; a payload that is not UTF-8 comes as `payloadBase64` instead;
`payloadTruncated: true` when cut. Where the payload may not be served, `payload` is
`{"hidden": "<code>", "reason": "<text>"}`. A segment the source lacks or a position it does not hold is 404.

**Tail**: `GET /api/v1/events/tail?type=orders.*` takes the search's filters except `from`, `to` and `cursor` (400:
a tail starts at the end), and answers `text/event-stream` (the page reads it with `fetch`, so the token stays in a
header):

```text
event: start
data: {"source":"snodra.events","segments":6,"endsAtMs":1793872800000}

event: record
data: {"source":"snodra.events","segment":"1","position":"5310","timestamp":1793871903001,"key":"order-43","headers":{"type":"orders.OrderPlaced"},"size":390}

event: heartbeat
data: {"nowMs":1793871915000}

event: end
data: {"reason":"maxDuration"}
```

`start` comes once the browser is positioned at the head of every segment: a record written after it is delivered.
`record` is a summary, never a payload (the record route serves it). `heartbeat` after at most 15 s without a
record, with the hub's clock. `end` closes the stream: `maxDuration` (the browser's tail duration, and never past
`SNODRA_SERVER_MAX_STREAM_DURATION`: the hub asks for 2 s less), `slowReader` (the reader fell too far behind; the
browser never waits for a reader), `shutdown` (the browser or this hub stops) or `failed` (the browser went away or
broke the stream). A reader that leaves cancels the browser's tail.

**Sources**: `GET /api/v1/events/sources`:

```json
{
  "sources": [
    { "source": "snodra.events", "segments": [ { "segment": "0", "first": "0", "head": "131" } ] },
    { "source": "snodra.events.dlt", "missing": true, "segments": [] }
  ]
}
```

**Lag**: `GET /api/v1/events/lag?source=snodra.events`:

```json
{
  "source": "snodra.events",
  "subscriptions": [
    {
      "subscription": "service-c.audit", "state": "Empty", "members": 0,
      "segments": [
        { "segment": "0", "committed": "120", "head": "131", "lag": 11 },
        { "segment": "1", "committed": null, "head": "4", "lag": null }
      ],
      "lag": 11
    },
    { "subscription": "service-b.default", "state": "Stable", "members": 2,
      "segments": [ { "segment": "0", "committed": "131", "head": "131", "lag": 0 } ], "lag": 0 }
  ],
  "truncated": false
}
```

Every subscription (on Kafka, a consumer group) with a committed position on the source, whether an instance reads
it now or not (that is the point), by lag (descending), then name. `state` is the event store's; `committed` and
`lag` are `null` on a segment without a commit; a subscription's `lag` is the sum of the known ones. `truncated: true`
when the browser stopped at its bound before listing every subscription. Reading the lag never joins a subscription
or moves its position.

### Payloads

A payload, the record's `payload` or a search's or tail's `q`, is served only when **all** hold, checked in this
order; the first that fails is the `hidden` code:

| Condition | `hidden` when it fails |
|---|---|
| `SNODRA_SERVER_EVENT_BROWSER_PAYLOADS=true` | `payloads-off` |
| a dashboard token or a write token is configured on this hub | `no-token-configured` |
| the request presents one of them (`Authorization: Bearer`) | `no-token-presented` (only possible with a write token and no dashboard token: reads are then open) |

The hub asks the browser for a payload, and passes `q` on, only when these hold; a payload the browser sends anyway
is dropped. `q` without them is 403 `{"error": "<reason>", "hidden": "<code>"}`. Every payload served writes one
`info` audit line `event payload served` (caller `dashboard-token` or `write-token`, source, segment, position,
size, correlation id) and counts in `snodra_server_event_payload_views_total`; every search or tail with `q` writes
one `event payload search` line (caller, source, correlation id; never the searched text). Payloads are never
logged, cached (`Cache-Control: no-store`), put in a metric, a search result, the tail or an error, and the page
renders them as text.

### Dashboard

The Events page ([Pages](/docs/server/dashboard/#pages)) appears only while `/api/v1/version` says `eventBrowser.installed`;
its payload text field only when `eventBrowser.payloads` (a browser is installed, the switch is on and a token is
configured). It reads this hub only, with the dashboard token, or the write token when the tab holds no dashboard
token. A time preset is turned into epoch ms when the search runs. The Processors page also reads
`/api/v1/events/lag` for the browser's default source, at most every 15 s, to list the subscriptions that no live
instance reports.

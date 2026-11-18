# Event browser

Search, inspect and tail events, and read consumer-group lag, without a Kafka client.

## Event browser

Decision record: ADR 0025. With `SNODRA_SERVER_KAFKA_BOOTSTRAP` set the
hub reads Kafka, read-only, on the topics of `SNODRA_SERVER_EVENT_TOPICS` only: it searches events, shows one record,
tails new ones and lists consumer groups with their lag. It works with no service running.

- **Read-only, no group of its own.** Short-lived consumers that `assign` and seek; none subscribes or commits, so no
  consumer group exists for the hub (`group.id` `snodra-server-browser-<hub id>` is never joined). Topics are never
  created.
- **Never in the way.** Every Kafka call runs on the blocking pool under a deadline; the router and the other HTTP
  handlers never wait on Kafka. Unset bootstrap: every route below is 404 `{"error":"event browser disabled: set
  SNODRA_SERVER_KAFKA_BOOTSTRAP"}`. Kafka down or slow: these routes answer 503 `{"error":"Kafka is unavailable: ..."}`;
  startup, readiness and routing are unaffected.
- **Bounded.** Per search: `SNODRA_SERVER_EVENT_SEARCH_MAX_SCANNED` records read (50 000),
  `SNODRA_SERVER_EVENT_SEARCH_MAX_RESULTS` results (100; `limit` defaults to 50), `SNODRA_SERVER_EVENT_SEARCH_TIMEOUT` (10 s)
  for everything Kafka does for it. Per hub: `SNODRA_SERVER_EVENT_MAX_SEARCHES` searches, record reads and group listings
  at once (4) and `SNODRA_SERVER_EVENT_MAX_TAILS` tails (4); one more is 429 with `Retry-After: 1`. A call keeps its slot
  until its Kafka work has ended, even when the request left or gave up first; no Kafka request waits longer than 5 s,
  so a call holds its slot at most its time budget plus 5 s, also when a broker hangs. A tail lasts
  `SNODRA_SERVER_EVENT_TAIL_DURATION` (15 min) and holds 256 records for a reader that is behind.
- **Access.** The dashboard API's rules: the dashboard token reads (or the write token), CORS for the peers, gone with
  `SNODRA_SERVER_DASHBOARD_ENABLED=false`. Payloads have rules of their own, below.
- **Plaintext Kafka only**, as the libraries; TLS and SASL to Kafka are not supported.

### Routes

| Route | Answer |
|---|---|
| `GET /api/v1/events` | one page of a search, newest first |
| `GET /api/v1/events/{topic}/{partition}/{offset}` | one record with every header, and its payload or why it is hidden |
| `GET /api/v1/events/tail` | server-sent events from the end of every partition |
| `GET /api/v1/consumer-groups` | every consumer group with committed offsets on a topic, with its lag |

`topic` (search, tail, groups) defaults to the first of `SNODRA_SERVER_EVENT_TOPICS`; any other value must be listed there
(400 otherwise, also in a record path). A listed topic that does not exist is `"missing": true` with nothing in it for a
search and the groups, 404 for a record and a tail.

**Search** parameters, every one optional (an empty value is no filter):

| Parameter | Matches |
|---|---|
| `from`, `to` | the record timestamp, inclusive; epoch ms or RFC 3339 (`2026-11-05T10:00:00Z`, `...+01:00`); resolved per partition with offsets-for-times and compared on every record. Producers stamp records (`CreateTime`), so timestamps may run out of order: `from` is exact; `to` reads on to the first record stamped more than 5 minutes after it, so it misses a record only when that record follows one stamped more than 5 minutes after `to` |
| `type` | header `type`, exact; a trailing `*` makes it a prefix (`orders.*`; `*` alone: any record with a type) |
| `key` | the record key, exact |
| `source`, `correlationId`, `userId`, `eventId` | header `source`, `correlationId`, `userId`, `id`, exact (the last header of the name) |
| `q` | a case-sensitive substring of the payload; only where payloads may be served to this request, else 403 |
| `limit` | results per page, 1 to `SNODRA_SERVER_EVENT_SEARCH_MAX_RESULTS`, default 50 |
| `cursor` | continues the search it came from (same topic and filters, else 400) |

A key or header value that is not UTF-8 is shown, and matched, with each such byte as `\xNN`. Each filter is at most
1 KiB. Every partition is read backwards at once, in chunks of 50 records growing to 500, and the partitions' matches
are merged by record timestamp (ties: partition, then offset, descending). A page ends at `limit` results
(`stoppedBy: "limit"`), at the scan budget (`"scanBudget"`) or the time budget (`"timeBudget"`), or when every partition
reached its lower bound (`exhausted: true`, `stoppedBy` and `cursor` null). The cursor holds where each partition goes
on: no record is skipped or repeated between pages, records written after the first page are not in later ones, and a
page that found nothing before its time budget still moves on past what it examined.

```bash
H="Authorization: Bearer $SNODRA_SERVER_DASHBOARD_TOKEN"
curl -s -H "$H" 'http://localhost:7001/api/v1/events?type=orders.*&from=2026-11-05T09:00:00Z&limit=2'
```

```json
{
  "topic": "snodra.events",
  "results": [
    {
      "topic": "snodra.events", "partition": 3, "offset": 1841, "timestamp": 1793871062114,
      "key": "order-42",
      "headers": {
        "type": "orders.OrderShipped", "id": "0193e6f0-...", "correlationId": "c-7f1e...",
        "timestamp": "2026-11-05T09:51:02.114Z", "source": "service-b", "userId": "u-17",
        "traceparent": "00-4bf9...-01"
      },
      "size": 212
    },
    { "topic": "snodra.events", "partition": 0, "offset": 977, "timestamp": 1793871060020, "key": "order-42",
      "headers": { "type": "orders.OrderPlaced", "id": "0193e6ef-...", "source": "service-a" }, "size": 388 }
  ],
  "scanned": 1500,
  "exhausted": false,
  "stoppedBy": "limit",
  "cursor": "eyJmIjoiOWE0YjJkMGUxZjNjNzE4OCIsInAiOltbMCw5NzddLFsxLDYyMF1dfQ"
}
```

A result is a **summary**, never a payload: where the record is, its timestamp (`null` without one), its key (`null`
without one; at most 128 bytes, `keyTruncated: true` when cut), the library headers it carries (at most 256 bytes each)
and the payload's size in bytes. The next page: the same query plus `&cursor=<cursor>`.

**Record**: `GET /api/v1/events/snodra.events/3/1841` answers the summary plus `allHeaders` (every header in record
order, at most 64, `headersOmitted` counts the rest: `name` at most 128 bytes, `value` at most 1 KiB, or `valueHex` when
the value is not UTF-8, `truncated` when cut) and the payload:

```json
{
  "topic": "snodra.events", "partition": 3, "offset": 1841, "timestamp": 1793871062114, "key": "order-42",
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

`payload` is the UTF-8 text (at most 256 KiB; pretty-printing is the page's job), `null` for a record without a
payload; a payload that is not UTF-8 comes as `payloadBase64` instead; `payloadTruncated: true` when cut. Where the
payload may not be served, `payload` is `{"hidden": "<code>", "reason": "<text>"}`. An offset outside the partition, a
partition the topic lacks, and a compacted or deleted offset are 404; a partition or offset that is not a non-negative
number is 400.

**Tail**: `GET /api/v1/events/tail?type=orders.*` takes the search's filters except `from`, `to` and `cursor` (400),
and answers `text/event-stream` (the page reads it with `fetch`, so the token stays in a header):

```text
event: start
data: {"topic":"snodra.events","partitions":6,"endsAtMs":1793872800000}

event: record
data: {"topic":"snodra.events","partition":1,"offset":5310,"timestamp":1793871903001,"key":"order-43","headers":{"type":"orders.OrderPlaced"},"size":390}

event: heartbeat
data: {"nowMs":1793871915000}

event: end
data: {"reason":"maxDuration"}
```

`start` comes once every partition is positioned at its high watermark: a record written after it is delivered.
`record` is a summary, never a payload (the record route serves it). `heartbeat` every 15 s. `end` closes the stream:
`maxDuration` (`SNODRA_SERVER_EVENT_TAIL_DURATION`), `slowReader` (the reader fell 256 records behind; Kafka reading never
waits for a reader) or `shutdown`.

**Consumer groups**: `GET /api/v1/consumer-groups?topic=snodra.events`:

```json
{
  "topic": "snodra.events",
  "groups": [
    {
      "groupId": "service-c.audit", "state": "Empty", "members": 0, "topic": "snodra.events",
      "partitions": [
        { "partition": 0, "committed": 120, "highWatermark": 131, "lag": 11 },
        { "partition": 1, "committed": null, "highWatermark": 4, "lag": null }
      ],
      "lag": 11
    },
    { "groupId": "service-b.default", "state": "Stable", "members": 2, "topic": "snodra.events",
      "partitions": [ { "partition": 0, "committed": 131, "highWatermark": 131, "lag": 0 } ], "lag": 0 }
  ],
  "truncated": false
}
```

Every group the broker lists that committed an offset on the topic, members or not (that is the point), sorted by lag
(descending), then name. `state` is the broker's (`Stable`, `Empty`, `PreparingRebalance`, ...); `committed` and `lag`
are `null` on a partition without a commit; `lag` is the high watermark minus the committed offset (at least 0), the
group's the sum of the known ones. At most 500 groups, within the search time budget: `truncated: true` when some are
not listed. The committed offsets are read with an assign-only consumer of that group, which never joins or commits.

### Payloads

The hub never served payloads before; this is the exception (ADR 0025). A payload, the record's `payload` or a search's
`q`, is served only when **all** hold, checked in this order; the first that fails is the `hidden` code:

| Condition | `hidden` when it fails |
|---|---|
| `SNODRA_SERVER_EVENT_BROWSER_PAYLOADS=true` | `payloads-off` |
| a dashboard token or a write token is configured on this hub | `no-token-configured` |
| the request presents one of them (`Authorization: Bearer`) | `no-token-presented` (only possible with a write token and no dashboard token: reads are then open) |

`q` without them is 403 `{"error": "<reason>", "hidden": "<code>"}`. Every payload served writes one `info` audit line
`event payload served` (caller `dashboard-token` or `write-token`, topic, partition, offset, size) and counts in
`snodra_hub_event_payload_views_total`. Payloads are never logged, cached (`Cache-Control: no-store`), put in a metric, a
search result, the tail or an error, and the page renders them as text.

### Dashboard

The Events and Consumer groups pages ([Pages](dashboard.md#pages)) appear only when `/api/v1/version` says
`eventBrowser.enabled`; the payload text field only when `eventBrowser.payloads`. They read this hub only, with the
dashboard token, or the write token when the tab holds no dashboard token. A time preset is turned into epoch ms when
the search runs and kept for "Load more".

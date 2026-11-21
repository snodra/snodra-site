# Dashboard

The embedded UI: topology, processors, dead letters and the event browser.

## Dashboard

A web dashboard is compiled into the binary and served on the HTTP port: open
`http://localhost:7001/` (it redirects to `/ui/`). It shows what the topology view shows, plus who
calls whom and how that goes, and controls the services' event processors.

> **Authentication is opt-in for reads.** Without `SNODRA_SERVER_DASHBOARD_TOKEN` the dashboard and
> the reads of `/api/v1/` are open to anyone who reaches port 7001: keep the
> port on the private network (the page footer says the same). With the token set the page asks
> for it and every data endpoint needs it; see [Security](configuration/index.md). The only writes, the
> [processor controls](processor-control.md), always need the write token or an ACL credential with
> `control = true`, and are off when neither is configured.

| Page | Shows |
|---|---|
| Overview | totals (services, instances and how many are stale, types, in flight, queued, requests and errors over the window); a graph in three columns, sender services, types, owner services, with edge thickness by request count (log scale) and colour by error share (1 % warning, 5 % critical); hovering or focusing a node follows its traffic; a table of the same edges with requests, errors, p50 and p99 |
| Services | every service with its event processors (a count linking to the Processors page and a dead-letter badge) and its live instances: instance id, client version, permits, queued, in flight as handler and as sender, load factor, tags, heartbeat age with a stale flag, connected since, the hubs it reports (flagged when this hub is missing or the report is older than 15 s); the types each service handles. With peers under "All hubs": every reachable hub's instances merged by instance id, with "Seen by" and per-instance disagreements |
| Types | every type: kind, owners (with a "shared" badge for a shared query type), live instances, state (owned, orphaned for how long, no owner), senders, requests, errors, p50, p99; filters by text, kind and problems |
| Settings | hub id, version, start time, dashboard build, and every `SNODRA_SERVER_*` setting with its effective value and default |
| Processors | every (service, processor): group, topic, worst state over its instances, instances, partitions, lag (sum of the known lags), dead letters (or the mode `topic` / `log`), the latest error with its age; a row opens to every instance's report and partitions (position, committed, high watermark, lag), kept open in the URL (`#/processors?open=service-b/orders`); filters by text and problems. Under "All hubs" merged over every reachable hub, the freshest report of an instance winning (see [Event processors](event-processors.md)) |
| Dead letters | the processors that keep letters, and per processor (`#/dead-letters?service=…&processor=…`) its letters as one instance lists them through the hub (no payloads); with a write credential Retry, Retry all and Discard (confirmed). Read on demand, not live |
| Events | only while an [event browser](event-browser.md) is connected: a search form (source, time presets or from/to, type with `*` prefixes, key, service, correlation id, user id, event id, payload text where payloads are served), results newest first with "Load more" and the scan statistics, a record's headers and payload (pretty-printed JSON) or the reason it is hidden, a tail (new rows drawn once per animation frame, at most 500 kept, pause; `tail=on` in the page's URL opens it tailing); type and correlation id link to a search. This hub only. See [Event browser](event-browser.md) |

Filters live in the URL (`#/types?q=orders&kind=QUERY`), so a filtered view can be linked. With
`SNODRA_SERVER_GRAFANA_URL` set the header links to Grafana. With `SNODRA_SERVER_PEERS` set the header
lists this hub and every peer with its reachability, and offers "All hubs" (the default,
remembered per browser) or "This hub"; see [Multiple hubs](#multiple-hubs).

- any client can create thousands of types and edges by sending type names
  nobody owns (`NO_HANDLER`), so the pages draw a bounded amount. The graph draws at most 60
  type nodes (registered types first, then by requests) plus up to 40 more with a problem (no
  owner, orphaned, 1 % errors or more), and says how many more are hidden; the filter and the
  Types page reach the rest. The edges table and the Types table show at most 200 rows (the
  busiest edges; the first types) with a "showing 200 of N" note; filters search every row. A
  refresh redraws the graph only when its nodes or edges change, otherwise it updates edge
  widths, colours and labels in place.

### Pages

| Page | Content |
|---|---|
| Overview | Totals: services, instances (and how many are stale), types (commands, queries), in flight, queued, requests and errors over the window. A graph in three columns, sender services, types, owner services, drawn as SVG and laid out by the page itself: edge thickness by request count (log scale), colour by error share (1 % warning, 5 % critical; idle owner edges thin and grey); orphaned types and types nobody owns are flagged; hovering or focusing a node follows its traffic through the graph. Below it the same edges as a table: sender, type, owner, requests, errors, p50, p99 |
| Services | Each service, the types it handles, its event processors (a count linking to the Processors page, and its dead letters as a badge), and its live instances: instance id (with an `authenticated` or `unauthenticated (permissive)` badge when access control is on), client version, permits left, queued, in flight as handler and as sender, load factor, tags, heartbeat age with the stale flag, connected since, and the hubs the instance reports (flagged when this hub is missing or the report is older than 15 s). With peers and "All hubs": every reachable hub's instances merged by instance id, a "Seen by" column and the disagreements per instance |
| Types | Each type: kind, owners (a "shared" badge for a shared query type), live instances, state (owned, orphaned for how long, no owner), senders, requests, errors, p50, p99; filters by text, kind and "only problems" |
| Settings | Hub id, version, start time and uptime, dashboard build, and every `SNODRA_SERVER_*` setting with its effective value and default |
| Processors | Each (service, processor): consumer group, topic, the worst state of its instances (`PAUSED` while paused, `STOPPED` with the operation id while a reset holds it), a `replaying` badge, instances reporting, assigned partitions, lag (sum of the known lags), dead letters (or the mode, `topic` or `log`; the count links to the Dead letters page), the latest error with its age; filters by text and "only problems". A row opens to every instance's report: state, report age, totals and its partitions (position, committed, high watermark, lag, and the replay end while it replays); open rows are kept in the URL (`#/processors?open=service-b/orders`). With peers and "All hubs": every reachable hub's reports merged, an instance seen by several hubs counted once with its freshest report ([Event processors](event-processors.md)). With a write credential: Pause or Resume and Reset per row ([Processor control](processor-control.md)) |
| Dead letters | The processors that keep letters in a collection, and per processor (`#/dead-letters?service=service-b&processor=audit`) its letters as one instance lists them through the hub: id, reason, event type, key, partition and offset, attempts, the error, when it was parked, the letter it waits behind; no payloads. With a write credential: Retry, Retry all and Discard (confirmed). Read on demand, not live |
| Events | Only while an event browser is connected ([Event browser](event-browser.md)). A search form (source, a time range: the last 15 minutes, hour, 24 hours, 7 days, any time, or from/to; type, `orders.*` for a prefix; key, service, correlation id, user id, event id; payload text, a substring, only where this hub serves payloads), the results newest first (time, type, key, segment / position, service, correlation id) with "Load more" and the scan statistics ("Scanned 12,000 records, stopped by the time budget"), a type or correlation id links to a search by it. A record opens to its time, key, size, every header and its payload, pretty-printed when it is JSON, or the reason it is hidden. A Tail toggle prepends records as they arrive (drawn once per animation frame, so a busy source does not freeze the tab; at most 500 kept), with Pause; `tail=on` in the page's URL opens it tailing. This hub only (every hub's event browser reads the same event store) |

Navigation is by URL hash (`#/types?q=orders&kind=QUERY`), so a filtered view can be shared as a
link. The header shows the hub id, version and uptime, the live state (stream, polling,
offline), with `SNODRA_SERVER_PEERS` set every hub with its reachability and an "All hubs" / "This
hub" choice, and, with `SNODRA_SERVER_GRAFANA_URL` set, a Grafana link. Light and dark follow the
system setting; the page works down to phone width (the graph and wide tables scroll inside their
card), by keyboard (skip link, focusable graph nodes, labelled controls), and shows every status
by shape and label as well as colour. No external font, script or style is loaded.

### JSON API

`GET`, JSON (camelCase), `Cache-Control: no-store`, under `/api/v1/`:

| Path | Content |
|---|---|
| `topology` | the [topology snapshot](topology.md) |
| `types` | per type: `type`, `kind`, `owners` (every owner, sorted), `shared`, `registered` (false for a type only seen in traffic, answered `NO_HANDLER`), `instances`, `liveInstances`, `orphaned`, `orphanedForMs`, `senders`, `traffic {count, errors, p50Ms, p99Ms}`; `windowMs` |
| `graph` | `nodes`: services (`service:<name>`, `instances`, `staleInstances`) and types (`type:<name>`, `typeKind`, `owners`, `shared`, `registered`, `orphaned`); `edges`: `send` (sender service -> type, traffic in the window) and `handle` (type -> owner service, for every owned type and every owner of a shared type, traffic merged over its senders and not split by owner), each with `count`, `errors`, `p50Ms`, `p99Ms`; `totals`; `windowMs`, `maxEdges`, `evictedEdges` |
| `settings` | `settings[]`: `name`, `value`, `default`, `secret`, `description`. A secret setting is listed with `value: null` and never serialized: the two dashboard tokens are. URL user info is shown as `***` |
| `version` | `hubId`, `version`, `startedAtMs`, `nowMs`, `buildId`, `grafanaUrl`, `windowMs`, `peers` (`SNODRA_SERVER_PEERS` as origins), `eventBrowser` (`installed`: an event browser is connected; `payloads`: a request presenting a token would see payloads) |
| `processors` | the event processors per service: `hubId`, `nowMs`, `services[]` (`serviceName`, `deadLetters`, `processors[]`), each processor aggregated over its instances; see [Event processors](event-processors.md) |
| `services/{service}/processors/{processor}/dead-letters` | a processor's dead letters, listed by one instance; see [Processor control](processor-control.md), which also documents the mutating routes (`POST`, `DELETE`) under `services/` |
| `events`, `events/{source}/{segment}/{position}`, `events/tail`, `events/sources`, `events/lag` | the [event browser](event-browser.md) |
| `stream` | server-sent events, event `summary` (the page reads it with `fetch` so the token stays in a header): `hubId`, `buildId`, `nowMs`, `totals`, `staleInstances`, `requests`, `errors`, `revision`; sent at once, within 0.5 s of a change and at least every 2 s |

- `revision` changes with services, instances, their registrations, stale flags, the hubs instances report, type ownership and the set of edges, not with counters or ages. The page refreshes the
  view it shows on each summary (at most once a second) and at once when `revision` changes;
  while the stream is unavailable it polls `topology` every 2 s.
- **Builder call:** at most 64 streams are open at once; beyond that the stream answers `503` and
  the page polls. Streams end at shutdown.

### Edge statistics

The router counts each request when it reaches its terminal state, on its `(sender service,
type)` edge: one request, one error unless the outcome is `ok`, and its latency (receipt to
terminal message). A scatter-gather is one request: latency to its `ReplyEnd`, an error when no
part succeeded. The owner side of the graph is the merge of a type's edges.

| Aspect | Rule |
|---|---|
| Window | `SNODRA_SERVER_EDGE_STATS_WINDOW` (5 min) in ten slots (30 s): a view covers between 4.5 and 5 minutes; expired edges are swept once per slot |
| Latency | sparse log-scale histogram per slot, 8 bins per power of two; p50 and p99 within about 4.4 % |
| Cap | `SNODRA_SERVER_EDGE_STATS_MAX_EDGES` (10 000); a new edge at the cap drops the least recently used edges, 1 % of the cap at a time (at least one), counted in `evictedEdges` and shown on the overview |
| Names | sender and type names longer than 200 bytes are cut (ending in `…`) |
| Not routed | `NO_HANDLER`, `INVALID_REQUEST` and duplicate ids count as errors without a latency |
| Sender gone | not counted, as in `snodra_hub_requests_total` |
| Disabled | `SNODRA_SERVER_DASHBOARD_ENABLED=false` collects nothing |

- **Builder call:** a type's owner edge includes the `NO_HANDLER` answers it got while its owner
  had no instance, so a dead owner shows up red on its own edge; the type is flagged orphaned.
- **Builder call:** memory per edge is its key plus at most ten slot sketches; an edge whose
  latency stays within one order of magnitude holds about 27 bins per slot.

### Assets, caching and headers

- The page is plain HTML, one stylesheet and JavaScript ES modules written for the hub (no
  framework, graph library, package manager or build step), compiled in with `rust-embed`.
- `/ui/` is `no-cache` and loads everything from `/ui/v/<build>/`, `<build>` being a hash of all
  embedded files; those URLs are `immutable`, so a new hub version is picked up at once. A
  request for another build id gets the current file `no-cache`, and an open tab of an older
  build shows a reload banner.
- Every dashboard and API response carries `Content-Security-Policy: default-src 'self';
  script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self' <peers>; font-src 'self';
  object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` (`<peers>` is
  `SNODRA_SERVER_PEERS`, nothing without peers),
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and `X-Frame-Options: DENY`.
  Names that clients register reach the page only as text, also those read from peer hubs.
- `/api/v1/*` answers CORS only for an `Origin` that is exactly one of `SNODRA_SERVER_PEERS`
  (`Access-Control-Allow-Origin: <that origin>`, `Vary: Origin`; never a wildcard or
  credentials; `Access-Control-Allow-Headers: accept, authorization`, so a page can forward the
  dashboard token); a preflight is `204` for such an origin asking for `GET`, `403` otherwise,
  and never needs the token. The
  page and its assets never answer CORS.
- **Builder call:** `/` and `/ui` redirect to `/ui/` with `307` and the relative `Location: ui/`,
  so the redirect works behind a proxy that mounts the hub under a path and is not cached past a
  `SNODRA_SERVER_DASHBOARD_ENABLED=false`.


## JSON API

All under `/api/v1/`, `GET`, JSON (camelCase), `Cache-Control: no-store`:

| Path | Body |
|---|---|
| `topology` | the topology snapshot, as the gRPC `Topology` returns it |
| `types` | `types[]`: `type`, `kind`, `owners` (a list, room for shared query types), `registered` (false for a type only seen in traffic, i.e. answered `NO_HANDLER`), `instances`, `liveInstances`, `orphaned`, `orphanedForMs`, `senders`, `traffic {count, errors, p50Ms, p99Ms}`; `windowMs` |
| `graph` | `nodes[]` (`kind: service` with `instances`, `staleInstances`; `kind: type` with `typeKind`, `owners`, `registered`, `orphaned`; ids `service:<name>`, `type:<name>`), `edges[]` (`from`, `to`, `role: send` sender -> type, `role: handle` type -> owner merged over senders, every owned type even without traffic; `count`, `errors`, `p50Ms`, `p99Ms`), `totals`, `windowMs`, `maxEdges`, `evictedEdges` |
| `settings` | `settings[]`: `name`, `value`, `default`, `secret`, `description`; a secret is listed with `value: null` (none exist yet; URL user info is replaced by `***`) |
| `version` | `hubId`, `version`, `startedAtMs`, `nowMs`, `buildId`, `grafanaUrl` (never with user info), `windowMs`, `peers` (`SNODRA_SERVER_PEERS` as origins; empty without peers), `eventBrowser` (`installed`, `payloads`) |
| `events`, `events/{source}/{segment}/{position}`, `events/tail`, `events/sources`, `events/lag` | the [event browser](event-browser.md) |
| `processors` | the event processors per service, aggregated over the instances (see [Event processors](event-processors.md)) |
| `services/{service}/processors/{processor}/dead-letters?limit=` | a processor's dead letters, listed by one instance; the mutating routes under `services/` are in [Processor control](processor-control.md) |
| `stream` | server-sent events: `summary` (`hubId`, `buildId`, `nowMs`, `totals`, `staleInstances`, `requests`, `errors`, `revision`) at once, within 0.5 s of a change and at least every 2 s; the page refreshes its view on each and polls `topology` every 2 s while the stream is unavailable |

- at most 64 streams are open at once; the 65th gets `503` and its page polls.
  Streams end at shutdown.
- all streams read one shared summary, recomputed every 0.5 s only while at
  least one stream is open (edge totals are kept as requests arrive, so this does not walk the
  edges); without a stream nothing is computed.
- `revision` hashes services, instances, their registrations, stale flags and
  reported hubs, type ownership and the set of edges, not counters or ages, so a page can
  refresh at once on a structural change.

### Edge statistics

The router counts every request that reaches a terminal state on its `(sender service, type)`
edge: requests, errors (any outcome but `ok`) and its latency. In memory only, like everything
in the hub.

- Window: `SNODRA_SERVER_EDGE_STATS_WINDOW` (5 min) in ten slots (30 s each), so a view covers
  between 4.5 and 5 minutes. Expired edges are swept once per slot.
- Latency: a sparse log-scale histogram per slot, 8 bins per power of two; p50 and p99 are off by
  at most about 4.4 %.
- requests the hub answers without routing them (`NO_HANDLER`,
  `INVALID_REQUEST`, a duplicate id) count as errors but have no latency, so they do not drag
  the percentiles to zero. Requests whose sender disconnected are not counted (as in
  `snodra_hub_requests_total`). The `handle` edge of a type merges all its requests, including
  `NO_HANDLER` answers while the owner had no instance.
- cap `SNODRA_SERVER_EDGE_STATS_MAX_EDGES` (10 000). At the cap a new edge drops
  the least recently used edges, 1 % of the cap at a time (at least one), counted in
  `evictedEdges` and shown on the overview. Names longer than 200 bytes are cut (with `…`), so
  a client cannot grow the map with huge type names.
- error colours start at 1 % (warning) and 5 % (critical) of the window's
  requests; below 1 % the edge keeps the neutral colour and the table still shows its errors.
- `SNODRA_SERVER_DASHBOARD_ENABLED=false` also stops collecting the statistics.

### Assets, caching and headers

`ui/` holds `index.html`, `app.css`, `favicon.svg` and plain ES modules (`app.js`, `api.js`,
`live.js`, `hubs.js`, `graph.js`, `dom.js`, `format.js`, `pages/*.js`). There is no third-party code, no
package manager and no build step; the files are compiled into the binary with `rust-embed`.

- `/ui/` is served `no-cache` and references every asset under `/ui/v/<build>/`, where `<build>`
  is a hash of all embedded files. Those URLs are `immutable`, so a new hub version is picked up
  at once and nothing stale is cached. a request for another build id is
  answered with the current file, `no-cache` (a tab open across an upgrade keeps working; it
  also shows a "reload" banner).
- Every dashboard and API response carries `Content-Security-Policy: default-src 'self';
  script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self' <peers>; font-src 'self';
  object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` (`<peers>`:
  the `SNODRA_SERVER_PEERS` origins, nothing without peers), plus
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`.
  Names registered by clients only ever reach the page as text, also those read from peers.
- `/` and `/ui` redirect to `/ui/` with `307` and a relative `Location`
  (`ui/`), so the redirect works behind a proxy that mounts the hub under a path and is not
  cached past a `SNODRA_SERVER_DASHBOARD_ENABLED=false`.

### Multiple hubs

Hubs never
talk to each other; each instance connects to every hub. The hub side:

- **Instance status.** A client sends `ClientMessage.status`
  (`InstanceStatus{connected_hub_ids, handlers_in_flight}`, every 5 s). The hub keeps the latest
  report per session, replaced by each and dropped with the session, and shows it as
  `connectedHubIds` / `statusAgeMs`. at most 64 ids of at most 128 bytes are
  kept; empty, over-long (ignored, never cut) and duplicate ids are dropped.
- **Dashboard peers.** The page reads `/api/v1/topology` of every `SNODRA_SERVER_PEERS` entry from
  the browser (3 s timeout each; on every refresh of a merging page, otherwise every 5 s for the
  header) and, under "All hubs", merges them: the Services page by instance id with "Seen by",
  the Overview with totals over all hubs and a list of disagreements (at most 200 rows): an
  instance missing on a reachable hub, an instance with different types on different hubs, a
  type owned by different services on different hubs, an instance whose reported hubs omit a
  reachable hub. An unreachable peer is shown as unreachable, not as a disagreement. The traffic
  graph and the Types page stay per hub.
- **CORS.** `/api/v1/*` answers an `Origin` that is exactly one of `SNODRA_SERVER_PEERS` with
  `Access-Control-Allow-Origin: <that origin>` (and `Vary: Origin` whenever peers are set), never
  a wildcard, never credentials; a preflight is `204` (`GET` only) for such an origin and `403`
  otherwise. Other origins, the page and its assets get no CORS header.

Developing the page: edit `ui/`, `cargo run` (assets are embedded in debug builds too) and
reload. `tests/dashboard_ui.rs` checks that every referenced asset and every import resolves,
and loads each page in headless Chrome when one is installed (`SNODRA_SERVER_TEST_BROWSER=<path>`
picks a binary, `none` skips; CI without a browser runs the static checks only).


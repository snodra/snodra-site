# Event processors

How the hub presents the processor status every service instance reports.

## Event processors

Decision record: ADR 0022. A service's Kafka
event handlers run in **event processors**: `default` for the handlers without a processing group, and one per named
processing group (`@ProcessingGroup("orders")` in Kotlin, `builder.event_in("orders", …)` in Rust); each has its own
consumer group, `<service group>.<name>` (`<service group>.default` for `default`). Each instance reports its
processors every 5 s in `InstanceStatus.processors` on each of its streams. The hub shows what the libraries measured
(it reads no Kafka for this), and keeps nothing but the latest report of each live session. The lag of every consumer
group, live members or not, as Kafka reports it: [Event browser](event-browser.md), consumer groups.

- **Kept** per session; replaced by each report, dropped with the session.
- **Bounded:** at most 32 processors per report, 1024 partitions and 256 event types each; a name is cut at 64 bytes,
  group and topic at 256, the last error at 512, an event type at 256, the mode at 32, always at a UTF-8 boundary; an
  empty or repeated name, a negative or repeated partition and empty event types are dropped; offsets below -1 read as
  -1 (unknown). Nothing is ever refused.
- **Shown** in the topology (`InstanceTopology.processors`, the JSON field `processors`, a table per service in
  `snodra-server --topology`), in `GET /api/v1/processors` and on the dashboard's Processors page.

`GET /api/v1/processors` (dashboard API: the dashboard token, CORS for the peers, off with
`SNODRA_SERVER_DASHBOARD_ENABLED=false`) aggregates per service and processor:

| Field | Meaning |
|---|---|
| `name`, `groupId`, `topic`, `deadLetterMode` | the processor; group, topic and mode as the freshest report has them |
| `state` | the worst state of its instances: `FAILING`, `UNSPECIFIED` (unknown), `STARTING`, `PAUSED`, `STOPPED`, `RUNNING` |
| `instancesReporting` | instances that report the processor |
| `assignedPartitions` | distinct partitions over them (a partition two instances report during a rebalance counts once, as the freshest report has it) |
| `lag` | the sum of the known lags of those partitions; `null` when none is known |
| `deadLetters` | the highest count an instance reported (each samples the service's `dead_letters` collection every 30 s); 0 outside mode `collection` |
| `processedTotal`, `failedTotal` | sums over the instances (each counts since its own start) |
| `eventTypes` | the union of its instances' event types |
| `lastError` | `{message, atMs, instanceId}` of the most recent error, `null` when none |
| `instances[]` | each instance's report as kept (the topology fields above) with `instanceId` and `statusAgeMs` |

`services[].deadLetters` sums its processors'. Services that report no processor are not listed. The dashboard
re-aggregates in the browser from `instances[]`, also over every reachable peer (ADR 0022 ruling 10); a peer that
does not answer is shown unreachable.

Dead letters themselves (the `dead_letters` collection, the `topic` and `log` modes, the local `DeadLetters` admin API
for list, retry and discard) belong to the libraries: [02-messaging.md, Event processors and dead
letters](https://snodra.damoreira.com/messaging/). Pausing, resuming and replaying a processor and
working its letters through the hub: [Processor control](processor-control.md). A report also carries
`replaying`, `operationId` and, per partition, `replayUntil`; an aggregate replays when any instance does and shows the
operation id of the freshest report that names one.

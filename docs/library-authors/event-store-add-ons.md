# Writing an event-store add-on

This page is for you if you write an event-store add-on, for an existing Snodra library or for a new one, in any
language: the piece that publishes a service's events to a log (or, later, a queue) and reads them back for its event
processors. After reading it you know the operations an add-on provides and the guarantees each owes, the capabilities
it may declare, the protocol fields it fills, the conformance checks it must pass, and the five queries an event
browser answers. The message store, which an add-on works with but never replaces, is
[message-store-add-ons.md](message-store-add-ons.md).

**Event store** only says where the events are kept. Snodra does no event sourcing, and the hub keeps no events: it
stays stateless. The core library knows no event store; each event store is an add-on with a name (`kafka`,
`rabbitmq-streams`, `memory`, or a third party's) and a declared set of capabilities.

## What an add-on owes

Every event-store add-on must provide (the kit checks named in brackets prove each, see
[The conformance kit](#the-conformance-kit)):

| Required | Meaning |
|---|---|
| Publish | the outbox relay hands it one event (source, id, type, key, headers, JSON payload); it returns once the event store accepted it. Two publishes of one key, the second called after the first returned, are delivered in that order |
| One subscription per processor | each subscription name (one per event processor) receives every event of its source, whatever other processors and services do (`every_processor_gets_every_event`) |
| Competing instances | the subscriptions of one name share its segments; adding one spreads them (`instances_share_a_processor`) |
| Order per key | events with the same key go to one segment and reach a processor in publish order (`same_key_arrives_in_publish_order`) |
| At-least-once with acknowledgement | the library acknowledges after the handler and the processed-event record committed; what was not acknowledged comes again, and the message store's processed events skip it (`unacked_delivery_is_redelivered`, `redelivered_after_commit_is_skipped`) |
| Pause and resume | a subscription stops delivering without losing its place (`paused_subscription_receives_nothing_and_resumes_in_place`) |
| The headers | the seven headers of [messages.md](messages.md#event-headers), and any other, travel as the event store's native metadata (`headers_round_trip`) |

A new subscription name starts at the earliest position of every segment.

## The operations

The operations below are those of the official interfaces: the Rust traits `event_store::EventStore`,
`event_store::Subscription`, `event_store::SubscriptionAdmin` and `event_store::EventBrowser` of `snodra_messaging` and the Kotlin interfaces in `com.damoreira.snodra.messaging.eventstore`
(suspend versions, without a browser). A library in another language shapes them in its own idiom; their meaning is
the contract.

**The add-on:**

- **name**: reported to the hub as `ProcessorStatus.event_store`.
- **capabilities**: what it offers beyond the contract ([Capabilities](#capabilities)), reported as
  `ProcessorStatus.capabilities`.
- **publish(event)**: appends the event to its source. An event carries its source (the service's events source, or its
  dead-letter source), its id (also in header `id`), its type name (also in header `type`), an optional key (the order
  key; none spreads events as the event store does), the headers (UTF-8 text, one value per name) and the payload (JSON
  bytes, carried as given). Fails with *rejected* when the event store will never take this event (too large, not
  authorized, a destination it cannot have: the relay gives it up at once), or *failed* when another try may succeed.
- **subscribe(name, source)**: joins the subscription `name` (`<service>.<processor>`, the service name or a configured
  prefix) on `source` as one more instance. The subscription returned is the caller's to close; an add-on whose
  subscribe is cancelled after it built one closes it itself.
- **admin(name, source)**: the reset side of a subscription, for a reset run while no instance reads it; *unsupported*
  without `replay`.
- **compare(a, b)**: the order of two positions of one segment. The core orders positions only through it.
- **browser()**: its event browser, present exactly when it declares `browse`. Only the Rust interface has this
  operation today; see [Capabilities](#capabilities) for what `browse` means in a library without it.

**A subscription** (one instance of one processor):

- **next()**: waits for the next assignment change (segments assigned, segments revoked) or delivery (segment,
  position, key, headers, payload, the event store's append time in epoch milliseconds). Nothing is delivered until it
  is called, and the core keeps calling it while paused: that keeps the membership alive. A new subscription's first
  event is an assignment, an empty one when it holds no segment, within a bound of its joining (10 s in both libraries,
  `FIRST_ASSIGNMENT_WITHIN`): an instance that joined and holds nothing is a member, idle, which the core reports
  running, never starting. A segment's events come in
  their order, each after the assignment naming the segment and before any revocation of it. Every revocation is
  followed by an assignment, an empty one when the instance holds nothing any more: the core reads a revocation alone
  as a reassignment still in progress. Dropping a pending `next()` loses nothing (the core races it with its shutdown
  and its timers). An error ends the subscription: the core closes it and subscribes again after a backoff.
- **ack(segment, position)**: acknowledges that delivery and every earlier one of the segment; a later subscription of
  the name resumes after it. It may reach the event store after the call returns; close flushes it.
- **redeliver(segment, position)**: hands that delivery and the segment's later ones out again without leaving the
  subscription (what the core does with an event it could not finish).
- **pause() / resume()**: stop and restart delivery without losing the place; a segment assigned while paused is paused
  at once; both idempotent.
- **segments()**: the assigned segments with their position (the next one delivered), committed position, head and lag,
  as last known; never a blocking call.
- **take_error()**: the latest trouble the subscription recovered from by itself (a lost connection, a failed
  reassignment), as text for `ProcessorStatus.last_error`.
- **close()**: leaves the subscription after flushing the acknowledgements; its segments go to the other instances.

**The admin** (capability `replay`), whose calls block (run them off the event loop):

- **members()**: the instances reading the subscription now; empty when none does.
- **plan(target)**: where a `ResetTarget` moves each segment, from the event store's current positions; nothing moves
  yet. One replay range per segment the target addresses: `from` the position it moves to, `until` the subscription's
  committed position before (empty when it had none). A target position the segment does not have is *invalid*.
- **apply(ranges)**: moves each range's segment's committed position to its `from`, all or nothing; refused with
  *subscribers active* while an instance reads the subscription.

Errors an add-on reports, and what the hub sees of them: *invalid* (a bad argument: an unknown segment, a position the
segment does not have; `ControlRefusal.CONTROL_REFUSAL_INVALID`), *subscribers active* (members still read the
subscription; `ControlRefusal.CONTROL_REFUSAL_SUBSCRIBERS_ACTIVE` with the members in the message), *unsupported* (the
capability is missing; `ControlRefusal.CONTROL_REFUSAL_UNSUPPORTED`), *rejected* and *failed* (above;
`ControlRefusal.CONTROL_REFUSAL_FAILED` when they end a control request).

## Capabilities

| Capability | What it enables | Kit checks |
|---|---|---|
| `replay` | reset to earliest, latest, a time or explicit positions; reset handlers, handlers that do not replay, replay ranges | `replay_from_earliest_redelivers_history`; without it, `admin_without_replay_is_unsupported` |
| `browse` | the event store can be read by an event browser: search by time, type, key and headers, one record, the sources, the subscriptions' lag, the live tail ([The event browser's queries](#the-event-browsers-queries)) | `search_finds_by_type_key_and_correlation`, `search_stops_at_bounds`, `tail_streams_new_events`, `browser_never_commits_a_position`; without it, `no_browser_without_capability` |
| `lag` | how far a subscription is behind, per segment (`SegmentStatus.lag`) | `lag_counts_unacked`; without it, `lag_unknown_without_capability` (no segment reports a lag) |
| `native-dead-letter` | the dead-letter mode `event-store`: what a processor cannot handle goes to the dead-letter source `<source>.dlt` | `dead_letter_source_receives` |

Capabilities are declared per store instance, from what that configured store can do: the RabbitMQ Streams add-on
declares `replay` only when its management API is configured, because only that API lists the instances reading a
subscription, which a reset needs ([RabbitMQ Streams wire rules](#rabbitmq-streams-wire-rules)).

`browse` says the event store can be read by an event browser. A library whose interfaces have no event browser (the
Kotlin library today) may still declare it for a store an event browser can read; the browser itself is then another
program (today the Rust-based `snodra-event-browser`, which reads every event store with a Rust add-on).

The hub and the dashboard offer only what an event store declares, and an instance answers a control action its event
store cannot do with `ControlRefusal.CONTROL_REFUSAL_UNSUPPORTED` and a reason. Dead letters stay in the message store
by default (mode `collection`), so they work on every event store. An add-on may report names of its own next to these.

## Segments and positions

A **segment** is a unit of the event store's order per key (a Kafka partition, a RabbitMQ partition stream, a segment
of the in-memory log); a **position** is a record's place in its segment. Both are opaque strings that only the add-on
reads (a decimal number on every first-wave store).

- At most 128 bytes each: the hub drops a segment named in more than 128 bytes and reads a longer position as
  unknown. An empty position means unknown or none.
- Segments are listed in the hub's order: names of ASCII digits only by their value, before every other name, which go
  by their bytes.
- Dead-letter ids and processed-event markers embed them: a letter is `<processor>:<source>:<segment>:<position>`, a
  stage-1 marker records the processor, source, segment and position so a reset deletes exactly the markers of its
  replay range.

The protocol fields an add-on's values end up in, through the library's status and control: `ProcessorStatus.subscription`,
`ProcessorStatus.source`, `ProcessorStatus.event_store`, `ProcessorStatus.capabilities`, `SegmentStatus.segment`,
`SegmentStatus.position`, `SegmentStatus.committed`, `SegmentStatus.head`, `SegmentStatus.lag` (-1 when unknown, never
negative otherwise), `SegmentStatus.replay_until`, `ResetTarget.positions` (`SegmentPosition` pairs), `ReplayRange` in
`ResetOutcome.ranges`, and `DeadLetterSummary.source`, `DeadLetterSummary.segment`, `DeadLetterSummary.position`.

## The conformance kit

One suite every event-store add-on runs, a third party's included, in the library's test module: Rust
`snodra_messaging::event_store::conformance::run_event_store_conformance(source, make_events, store)` (cargo feature
`testing`), Kotlin `com.damoreira.snodra.messaging.test.eventstore.EventStoreConformanceTest` in `snodra-messaging-test`
(subclass it). The kit needs:

- **a source** prepared with at least two segments (the competing-instances check spreads them over two instances), and,
  when the add-on declares `native-dead-letter`, its dead-letter source too; the kit must be its only publisher while it
  runs;
- **a way to make the add-on**, one call per service instance (an in-process store returns the same one each time);
- **a message store**, for the at-least-once check's markers;
- **with `browse`**, a browser that reads that source with bounds no lower than the defaults' results.

The checks run one after the other, each on subscription names of its own; each waits at most a minute for what the
event store does in the background. Every check is public, so a failing one can be run by itself. What each asserts:

| Check | Asserts |
|---|---|
| `headers_round_trip` | the seven headers, any other header, the key (or none) and the payload arrive as published |
| `same_key_arrives_in_publish_order` | events of one key arrive in publish order, all from one segment, each once; positions of a segment's deliveries increase by compare |
| `every_processor_gets_every_event` | two subscription names (two processors) each receive every event |
| `instances_share_a_processor` | two instances of one subscription split its segments (adding the second spreads them) and share its events: each event goes to one of them, and both get some; every revocation is closed by an assignment |
| `a_joining_instance_announces_its_first_assignment` | instances join one subscription one at a time, one more than its segments: every newcomer's first event is an assignment (an empty one when it holds nothing), within 10 s of joining |
| `an_instance_left_without_segments_closes_its_change` | instances join one subscription one at a time past its segment count: each segment stays held by one instance, every segment is held, and once two or more instances share it no former holder (an instance that held segments before the join) keeps every segment (how the segments spread beyond that is the add-on's); an instance left with no segment still receives the (empty) assignment that closes its revocation |
| `unacked_delivery_is_redelivered` | what a subscription did not acknowledge comes again, to the next subscription of the name after a close, and on a live one after redeliver; what it acknowledged does not |
| `redelivered_after_commit_is_skipped` | a crash after the handler's transaction committed and before the acknowledgement: the event comes again, its processed-event marker makes it a duplicate, and once acknowledged it does not come again |
| `paused_subscription_receives_nothing_and_resumes_in_place` | a paused subscription delivers nothing (paused before its first `next` too) while its assignment goes on; resumed, it delivers from where it stopped, each event once, in order |
| `replay_from_earliest_redelivers_history` | `replay`: while an instance reads the subscription its positions do not move; with none, a reset to earliest replays what it had acknowledged; the plan of each target moves the segments as documented |
| `admin_without_replay_is_unsupported` | without `replay`: the reset side of a subscription is refused as unsupported |
| `lag_counts_unacked` | `lag`: each segment's lag counts what the subscription has not acknowledged |
| `lag_unknown_without_capability` | without `lag`: no segment reports a lag |
| `dead_letter_source_receives` | `native-dead-letter`: the dead-letter source takes a letter (its `snodra-dlt-*` headers included) and delivers it as published |
| `search_finds_by_type_key_and_correlation` | `browse`: a search finds events by type (exact and prefix), key, correlation id and event id, newest first; a summary carries the event's place, key and library headers but no payload; a record carries every header and the payload only when asked; the sources list the source's segments |
| `search_stops_at_bounds` | `browse`: a page stops at its limit and continues from its cursor (the pages together are every match, newest first, none twice), and stops at its scan budget having read no more (at most this many records, but at least one from every segment not yet exhausted); a cursor only continues its own search; bounds it cannot honour are refused |
| `tail_streams_new_events` | `browse`: a tail starts at the end of every segment, then delivers the matching events appended after its start (each key in order, summaries only), heartbeats while nothing comes, and ends at its maximum duration |
| `browser_never_commits_a_position` | `browse`: browsing never moves a position and never joins a subscription |
| `no_browser_without_capability` | without `browse`: no browser |

The Kotlin kit has the same checks in camelCase (`headersRoundTrip`, `aJoiningInstanceAnnouncesItsFirstAssignment`,
`anInstanceLeftWithoutSegmentsClosesItsChange`, ...), without the browse checks (the Kotlin library has no event browser). Which checks prove which feature level: [feature-levels.md](feature-levels.md)
(`L2-EVENT-STORE-KIT`, `L3-EVENT-STORE-KIT`).

## The reference: the in-memory event store

Both libraries ship an in-memory event store (name `memory`) that passes the kit with no infrastructure. Read it first:
it is the contract with nothing else in the way.

- Every source is a log of a fixed number of segments (4 by default), named `0` to `n - 1`; an event goes to the
  segment of its key (FNV-1a 64 of the key's UTF-8 bytes, unsigned, modulo the segments), an event without a key to the
  next segment in turn. A position is the event's index in its segment.
- A subscription name keeps one committed position per segment; the instances of one name in the process share its
  segments, and a segment changes hands only once its holder gave it up, so two never read one segment at once.
- Capabilities `replay`, `browse` and `lag`; not `native-dead-letter`. Not durable: a startup warning says so.
- What `browse` means differs: the Rust in-memory event store has an event browser that answers the five queries below
  (and passes the kit's browse checks); the Kotlin one has no event browser, and `browse` there means only the read
  access tests use (its sources, its events by type and key, one event); nothing outside the process can browse it.
- Rust: `snodra_messaging::event_store::memory`; Kotlin: in the core library, selected with
  `snodra.messaging.event-store: memory`.

The durable add-ons of both libraries:

- **Kafka** (`kafka`): topic `snodra.events` with the event key as the record key, consumer groups
  `<service>.<processor>` (the default processor's `<service>.default` included), partitions as segments and offsets as
  positions, record headers, dead-letter topic `snodra.events.dlt`; every capability.
- **RabbitMQ Streams** (`rabbitmq-streams`, RabbitMQ 3.13 or later with the stream plugin): a super stream, single
  active consumers, server-side offset tracking; `browse`, `lag` and `native-dead-letter`, and `replay` with the
  management API. The two libraries share its streams, so its layout is a contract:
  [RabbitMQ Streams wire rules](#rabbitmq-streams-wire-rules).

Their modules and settings: [Kafka event store](../add-ons/kafka-event-store.md) and
[RabbitMQ Streams event store](../add-ons/rabbitmq-streams-event-store.md), with the libraries'
[Kotlin](../messaging/kotlin/index.md) and [Rust](../messaging/rust/index.md) pages.

## Kafka wire rules

The Kotlin and the Rust Kafka add-ons read and write the same topics, so instances of one processor in either language
share its consumer group. A third-party add-on that shares those topics must follow every rule below. The layout is
the one the Kafka add-ons have always written, kept byte for byte: one topic carries the events of every service, the
record key keeps one key's events in order on one partition, and each processor reads the whole topic in a consumer
group of its own. The library creates no topic: the infrastructure does (`snodra.events`, and `snodra.events.dlt` for
the dead-letter mode `event-store`).

| What | Rule |
|---|---|
| Source | a topic named as the events source (`snodra.events` by default) |
| Record | one record per event: the value is the JSON payload, carried as given; the key is the event key as UTF-8 bytes, no key for an unkeyed event |
| Headers | every header a record header: the name as given, the value as UTF-8 bytes, one value per name; the seven headers of [messages.md](messages.md#event-headers) always. **The order differs between the libraries** (the Rust add-on writes the other headers sorted by name, then `type`, `id`, `timestamp` and `source`; the Kotlin add-on writes them in the order it is given), so a reader looks a header up by its name, never by its place |
| Partitioner | the Java client's default for a keyed record: murmur2 of the key's bytes (seed `0x9747b28c`), masked positive (`& 0x7fffffff`), modulo the partition count. The Kotlin add-on runs the Java client's default; the Rust add-on sets librdkafka's `partitioner=murmur2_random` on its producer by default (a `partitioner` producer property, `SNODRA_KAFKA_PROPERTY_PARTITIONER`, overrides it). So one key lands on one partition whatever the language of the publisher, and keeps its order there. An empty key is a key, hashed like any other (as Java hashes an empty array), not the absence of one. Pinned values for 6 partitions: `order-1` → 4, `order-2` → 3, `order-42` → 0, `customer-7` → 1, `""` (empty) → 3. A record without a key has no placement rule: any partition |
| Segment, position, time | the segment is the partition number in decimal, the position the offset in decimal; an event's time is the record's timestamp |
| Consumer group | `<prefix>.<processor>` for every processor, `default` included; the prefix is the service name (Kotlin: or `snodra.messaging.events.subscription-prefix`). Offsets are committed by the group, never automatically, and **the committed offset is the next one to read** (the acknowledged offset plus one), as Kafka clients do; a new group starts at the earliest offset |
| Dead letter | the topic `<source>.dlt`, holding what the core publishes there: the original key, payload and headers plus the `snodra-dlt-*` headers ([messages.md](messages.md#event-headers)) |
| Group protocol | the official add-ons set neither the group protocol nor the partition assignor: each client's default. A Kotlin and a Rust instance form one group on the classic protocol with the assignor `range`, the one both clients' defaults share; a third-party member must offer it too |

**Confirmed across the two libraries** (Kafka 4.4.0, one broker, 2026-11-15): events published by one library are read
by the other with identical key, headers, payload and id; the pinned partitions hold for both publishers; a Kotlin and
a Rust instance share one group (classic protocol, `range`), a graceful leave hands the partitions over at the
committed offsets with nothing read again, and after a crash exactly the crashed instance's unacknowledged events come
again; the dead letters of either library are read by both.

## RabbitMQ Streams wire rules

The Kotlin and the Rust RabbitMQ Streams add-ons read and write the same streams, so instances of one processor in
either language share its work. A third-party add-on that shares those streams must follow every rule below. The
library creates no stream: the infrastructure does (`rabbitmq-streams add_super_stream snodra.events --partitions 6`, and for the dead-letter mode `event-store`
`rabbitmqadmin declare queue --name snodra.events.dlt --type stream --durable true`, with `--host`, `--port`,
`--username` and `--password` from outside a node; RabbitMQ 4.4 has no `rabbitmq-streams add_stream`).

| What | Rule |
|---|---|
| Source | a super stream named as the events source (`snodra.events` by default), partitions `<source>-0` to `<source>-(N-1)` with binding keys `0` to `N-1`; a plain stream (the dead-letter source `<source>.dlt`) is one partition |
| Routing | murmur3 x86_32 of the routing key's UTF-8 bytes, seed 104729, taken **unsigned**, modulo N, over the partitions in the broker's order (the stream clients' hash routing). The routing key is the event key, else the event id. Pinned values for 6 partitions: `order-1` → 0, `order-2` → 2, `customer-123` → 5, `order-7` → 3 (a signed modulo gets it wrong), `""` → 4 |
| Message | one AMQP 1.0 message per event, published with protocol version 1, **no sub-entry batching and no compression** (the Rust client cannot decode such chunks); exactly one `data` section, the JSON payload; `properties.message-id` the event id (an AMQP string); `properties.content-type` the symbol `application/json`; the message annotation `x-routing-key` (symbol key) holding the event key as a string, absent for an unkeyed event; every header an application property with an AMQP string value |
| Publisher | no producer name (no broker deduplication: the processed-event markers skip a republished event); each event waits for its publish confirm; `access_refused` or a frame over the limit is *rejected* (never retried), anything else *failed* |
| Segment, position, time | the segment is the partition's suffix after `<source>-` (`3`), `0` for a plain stream; the position is the offset in decimal; an event's time is its chunk's timestamp |
| Consumer | the name `<service>.<processor>` on **every** partition stream, with the subscribe properties `single-active-consumer=true`, `name=<service>.<processor>`, `super-stream=<source>` (omitted on a plain stream) and `snodra-member=<a random id per subscription instance>`, which lets the management API tell the instances apart |
| Offset tracking | per partition stream under the consumer name; **the stored value is the next offset to read** (the acknowledged offset plus one), not the "last processed" offset some clients store, which cannot express a reset to offset 0; none stored means the first offset. On activation the consumer answers the broker's consumer update with the stored offset (or the first) and skips the messages of the first chunk below it; on deactivation it stores what was acknowledged, reads it back, then answers. Positions are stored every 10 000 acknowledgements or 5 s, and at close. Never a client's automatic tracking |
| Reads that decide | offset reads, read-backs and a reset's stores go to each stream's leader |
| Replay | needs the management API (`GET /api/stream/consumers/{vhost}`, metrics collection on): the members of a subscription are the distinct `snodra-member` values of the consumers of that name on the source's partitions; a reset is refused while there is one, then stores each range's `from` |
| Dead letter | the plain stream `<source>.dlt`, holding what the core publishes there: the original key, payload and headers plus the `snodra-dlt-*` headers |
| Revocation | a partition that stops being active is a revocation followed by an assignment (possibly empty) |
| Connection names | `snodra-messaging` for a store, `snodra-event-browser` for a browser |

The official add-ons pin their clients (Rust `rabbitmq-stream-client` `=0.11.0`, Java `com.rabbitmq:stream-client`
1.13.1) and use each client's low-level client class: the high-level APIs can neither set `snodra-member` nor answer a
consumer update with a stored offset.

**Hand-over and node loss**, the same in both libraries: an instance that stops or crashes hands its partitions over
at once (the broker activates another consumer of the name). Both add-ons subscribe to each partition on its leader's
connection, so after the loss of a broker **node** every partition it led loses its active consumer in every instance,
and the broker gives none of them to another consumer until its `consumer_disconnected_timeout` passes (60 s by default
on RabbitMQ 4.x; measured 60.1 s on a 3-node 4.4.0 cluster). Nothing is lost and the order holds; the events wait.
Publishing resumes once the broker elected a new leader. The management API is one URL: with it configured (`replay`)
the store cannot open, so the service does not start, while that node is down (put it behind a load balancer). A hung
node (accepting connections, answering nothing) is found by the Rust add-on's liveness check in about 33 s, then its
subscriptions take up to about 20 s more to close; the Kotlin add-on has no liveness check of its own and relies on the
Java client's heartbeat, about 120 s on a quiet connection.

**Verified on a 3-node cluster** (RabbitMQ 4.4.0, the Rust add-on, about 115 000 events in 12 runs, 2026-11-15): no
event lost, order per key kept, redeliveries only after a crash or a lost connection and inside the documented window,
offsets resumed where they were stored, across a leader killed while publishing and while consuming, a non-leader node
lost, a hung leader, a leader moved, and the first configured host down. The Kotlin add-on was not run on a cluster;
its consumers sit on the leader's connection too.

Known limits, the same in both libraries: offset-tracking entries take offsets too, so positions have gaps and a lag
counts offsets for what is not received yet (it may overstate; what was received and not acknowledged is counted one by
one); after a crash up to 10 000 events or 5 s per partition are delivered again; a single active consumer cannot seek
in place, so a redelivery hands out again what the subscription kept unacknowledged; a partition added later is read
after the instances subscribe again; publishing is one confirmed event at a time (a batch publish in the contract is a
follow-up).

## The event browser's queries

The hub's dashboard and its `/api/v1/events*` routes read events through an **event browser**: a service connected to
the hub like any other, which handles five reserved query types. The official one is `snodra-event-browser`, built on
the Rust library's add-ons, so it can read every event store that has a Rust add-on declaring `browse` (today the
binary reads `kafka`: it does not offer the RabbitMQ Streams add-on's browser yet). An event browser written in
another language is allowed: any service whose credential holds the `event-browser` right and that answers the five
queries with the shapes below and within the hub's limits ([The hub's limits](#the-hubs-limits)). The hub turns each
HTTP call into one of these queries to a live instance that registered `snodra.events.Search`, and answers 404
`{"error":"event browser not installed"}` while none is connected. With the hub's access control on, only a credential
with the `event-browser` right may register `snodra.events.*` types. The hub's side (routes, payload rules, deadlines)
is on the server's [Event browser](../server/event-browser.md) page; the browser's own (settings, behaviour) on the
tools' [Event browser](../tools/event-browser.md) page.

| Type | Mode | Request | Answer |
|---|---|---|---|
| `snodra.events.Search` | point query | SearchRequest | SearchPage |
| `snodra.events.Get` | point query | GetRequest | EventRecord |
| `snodra.events.Sources` | point query | SourcesRequest | SourcesView |
| `snodra.events.Lag` | point query | LagRequest | LagView |
| `snodra.events.Tail` | streaming query (`RequestMode.STREAMING`) | TailRequest | a stream of tail parts |

JSON is camelCase everywhere; "optional" means the key may be absent; an empty text counts as absent in filters;
segments and positions are opaque strings of at most 128 bytes.

### Search

```json
{"source": "snodra.events",
 "filters": {"from": 1730000000000, "to": "2026-11-05T10:00:00Z",
             "type": "orders.*", "key": "order-42", "source": "service-b",
             "correlationId": "c-1", "userId": "u-1", "eventId": "e-1", "q": "\"total\":42"},
 "limit": 50, "cursor": "eyJmIjoi...", "maxScanned": 50000, "timeoutMs": 10000}
```

- Every field is optional (`{}` is valid: the default source, no filter, 50 results).
- `filters.from` and `filters.to`: a JSON number (epoch milliseconds) or a string (epoch milliseconds or RFC 3339);
  `type` exact, or a prefix ending in `*` (`*` alone: any typed event); `key` exact as shown (`\xNN` for bytes that are
  not UTF-8); `filters.source` is the **header** `source` (the publishing service), not the event store's source;
  `eventId` is the header `id`; `q` a payload substring (the hub sends it only under its payload rules). Each value at
  most 1 KiB.
- `limit` 1 to the browser's maximum results (default 50); `maxScanned` at least 1 and `timeoutMs` at least 1, both
  lowered to the browser's settings (a request may only lower a bound). `maxScanned` means at most this many records, but at least one from every segment not yet exhausted.
- `cursor`: the previous page's, with the same `source` and `filters` (else *invalid* "the cursor belongs to another
  search").

```json
{"source": "snodra.events",
 "missing": true,
 "results": [<summary>, ...],
 "scanned": 1234,
 "exhausted": false,
 "stoppedBy": "limit" | "scanBudget" | "timeBudget" | null,
 "cursor": "eyJmIjoi..." | null}
```

`missing` is present (true) only when the source is browsable but does not exist. A summary:

```json
{"source": "snodra.events", "segment": "3", "position": "42",
 "timestamp": 1730000000000 | null,
 "key": "order-42" | null,
 "keyTruncated": true,
 "headers": {"type": "...", "id": "...", "correlationId": "...", "timestamp": "...",
             "source": "...", "userId": "...", "traceparent": "..."},
 "size": 17}
```

`keyTruncated` only when the key was cut (128 bytes); `headers` holds those of the seven present, each cut to
256 bytes; `size` is the payload's size in bytes. Never a payload. Results are newest first; a page ends at its limit,
its scan budget or its time budget, or when every segment is exhausted (then `stoppedBy` and `cursor` are null).

### Get

Request: `{"source": "snodra.events", "segment": "3", "position": "42", "payload": true}` (`source` optional, `payload`
optional, default false; segment and position 1 to 128 bytes, else *invalid*).

```json
{..summary fields..,
 "allHeaders": [{"name": "type", "value": "orders.Placed"},
                {"name": "bin", "value": null, "valueHex": "00ff", "truncated": true}],
 "headersOmitted": 3,
 "payload": "{...}" | null,
 "payloadBase64": "/wA=",
 "payloadTruncated": true}
```

`allHeaders` in stored order, at most 64 (`headersOmitted` only when there were more); a name at most 128 bytes, a
value at most 1 KiB; `valueHex` only for a value that is not UTF-8, `truncated` only when cut. The payload keys only
when `payload: true` was asked: UTF-8 text as `payload`, a record without a value as `"payload": null`, anything else
as `payloadBase64` (and no `payload` key); `payloadTruncated` only when cut at the browser's payload bound. Not asked:
none of the three keys (the hub then adds its own `"payload": {"hidden": ..., "reason": ...}`). A segment or position
the source does not have is *not-found*; one the add-on cannot read is *invalid*.

### Sources

Request `{}`. Answer:

```json
{"sources": [{"source": "snodra.events", "missing": true,
              "segments": [{"segment": "0", "first": "0", "head": "120"}]}]}
```

Every configured source, the default first; `missing` only when the source does not exist (its `segments` then `[]`);
`first` is the first position held, `head` the position of the next event.

### Lag

Request `{"source": "snodra.events"}` (`source` optional). Answer:

```json
{"source": "snodra.events", "missing": true,
 "subscriptions": [{"subscription": "orders.projector", "state": "<the event store's>", "members": 0,
                    "segments": [{"segment": "0", "committed": "4" | null, "head": "10", "lag": 6 | null}],
                    "lag": 6}],
 "truncated": false}
```

Every subscription with a committed position on the source, with live instances or not, by `lag` descending, then
name; every segment of the source per subscription (`committed` and `lag` null where it committed none); the
subscription's `lag` is the sum of the known ones; `state` as the event store reports it, in its own names;
`truncated` when some subscriptions are not listed (too many, or the time ran out).

### Tail

Request: `{"source": "snodra.events", "filters": {..no from or to..}, "heartbeatMs": 15000, "maxDurationMs": 900000}`
(all optional; `from` or `to` is *invalid* "a tail takes no from: it starts at the end"; `heartbeatMs` 100 ms to 1 h,
default 15 s). Parts, one JSON object each:

```json
{"start": {"source": "snodra.events", "segments": 6, "endsAtMs": 1730000900000}}
{"record": <summary>}
{"heartbeat": {"nowMs": 1730000015000}}
{"end": {"reason": "maxDuration" | "slowReader" | "shutdown" | "failed"}}
```

`start` always comes first, once every segment is positioned at its head; `end` always last, nothing after it. A
heartbeat comes whenever no part came for `heartbeatMs`. `slowReader`: the reader fell the browser's tail buffer
(256 parts by default) behind; `shutdown`: the browser is stopping; `failed`: the browser's feed died. A refused tail
(*busy*, *not-found*, *unavailable*, *invalid*) fails before any part.

### Errors

```json
{"error": "invalid" | "not-found" | "busy" | "unavailable", "message": "<text>"}
```

The browser answers a refused call with `ErrorCode.HANDLER_ERROR`, `Error.message` the text and `Error.details` this
JSON. The hub maps them to HTTP 400, 404, 429 (with `Retry-After: 1`) and 503. A request that does not decode never
reaches the browser's code: the library answers `ErrorCode.INVALID_REQUEST` without such details, which the hub maps to
400. A reply error without the details is the hub's own (`ErrorCode.NO_HANDLER`: 404 "event browser not installed").

### Bounds

The browser's settings; requests may only lower them:

| Setting | Default | Allowed |
|---|---|---|
| sources | `snodra.events` (the first is the default of a call that names none; any other is *invalid*) | at least one, none empty |
| records scanned per search | 50 000 | at least 1 (a page reads at most this many records, but at least one from every segment not yet exhausted) |
| results per page | 100 | 1 to 1000 |
| time per search | 10 s | up to 5 min |
| searches at once, tails at once | 4 and 4 | 1 to 1024 each; one more is *busy* |
| tail duration | 15 min | 1 s to 24 h |
| tail buffer for a slow reader | 256 parts | up to 65 536 |
| payload served | 256 KiB | up to 16 MiB (the `snodra-event-browser` binary allows at most 1 MiB, so a record fits the hub's answers) |

A browser never commits a position and never joins a subscription (`browser_never_commits_a_position`): browsing must
not disturb the processors.

### The hub's limits

What the hub asks of a browser and accepts from it
([`src/events.rs`](https://github.com/snodra/snodra-server/blob/main/src/events.rs) of snodra-server); an answer over a
bound is a failure at
the hub (HTTP 502), never relayed:

| | Limit |
|---|---|
| A point query's answer (Search, Get, Sources, Lag) | at most 2 MiB of JSON |
| A tail part | at most 64 KiB |
| A cursor | at most 64 KiB; to come back in a GET it must also fit the URI, which the hub's HTTP server bounds at 65 534 bytes, path and other parameters included |
| A browser's error message | cut to 512 bytes |
| The timeout the hub asks of a point query | 30 s, clamped by the hub's own timeout rules like any client's |
| A search's `timeoutMs` | the hub asks its deadline minus 2 s, so the browser answers what it found before the hub gives up |
| A tail's `heartbeatMs` | the hub asks between 100 ms and 15 s (two fifths of its stream idle timeout) |
| A tail's `maxDurationMs` | 2 s under the hub's maximum stream duration |
| A filter value or a source | at most 1 KiB (the hub refuses longer ones before asking) |
| A segment or a position | at most 128 bytes |

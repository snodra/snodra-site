# Feature levels

This page is for library authors and for anyone choosing a library: it defines the four levels a Snodra library can
claim and, for each level, the conformance checks that prove it. After reading it you know what a library at a given
level does, which checks to pass before claiming it, and what each check asserts. A library claims the highest level
whose checks it passes together with every lower level's.

| Level | A library at this level can | Built on |
|---|---|---|
| **1 Core** | register handlers and send commands and queries through the hub, in every query mode (point, scatter-gather, streaming, subscription), authenticate (token, JWT, client certificate), and connect to several hubs | [protocol.md](protocol.md), [messages.md](messages.md) |
| **2 Events** | publish events through a message store's outbox to an event store, and handle them at least once with duplicates skipped | an event-store add-on and a message-store add-on: [event-store-add-ons.md](event-store-add-ons.md), [message-store-add-ons.md](message-store-add-ons.md) |
| **3 Processors** | run named event processors, report their status, answer the hub's processor controls (pause, resume, reset and replay), and park and work dead letters | level 2 |
| **4 Sagas** | run sagas and deadlines, with their commands relayed after the saga's transaction commits | level 3 |

Commands and queries alone need neither an event store nor a message store: a level 1 library is complete without
them.

## How the checks are named and run

Every check has a stable id, `L<level>-<NAME>`, and one sentence saying what it asserts. The "must" statements of
[protocol.md](protocol.md), [messages.md](messages.md) and [writing-a-library.md](writing-a-library.md) each name the
check that proves them. The **Proved by** column says what runs a check today:

- **runner**: the language-neutral conformance runner ([conformance.md](conformance.md)) runs it against a library's
  conformance service, through a real hub and through fake hubs of its own
  ([the conformance contract](https://github.com/snodra/snodra-conformance/blob/main/docs/contract.md#how-each-check-is-proved) says how, check by check).
- **runner, not checked yet**: a later runner version will run it; until then nothing checks it but each library's own
  tests.
- **kit**: the event-store and message-store conformance kits that ship with both official libraries.
  Every add-on runs them today; a library in another language ports them. The kits' checks are listed by name, with
  what each asserts, in [event-store-add-ons.md](event-store-add-ons.md#the-conformance-kit) and
  [message-store-add-ons.md](message-store-add-ons.md#the-conformance-kit). The names are the Rust kit's; the Kotlin
  kits hold the same checks in camelCase, and the message-store page lists the Kotlin names that differ
  ([Check names in both libraries](message-store-add-ons.md#check-names-in-both-libraries)).

## Level 1: Core

| Id | Check | Proved by |
|---|---|---|
| `L1-REGISTER-FIRST` | Every stream opens with a `Register` (non-empty service name and instance id, `Register.initial_permits` of at least 1) followed by a `Heartbeat`. | runner |
| `L1-HANDSHAKE-ACK` | The library counts a stream as registered only once its `RegisterAck` arrived, closes and reopens a stream that brought no ack within its handshake timeout, whatever echoes it got, and never waits on the ack of a later `Register` (the hub drops it when the session's buffer is full). | runner |
| `L1-EARLY-REQUESTS` | A request that arrives before the `RegisterAck` is served and counted against the permits. | runner |
| `L1-REJECTION` | A `Register` refused with `ALREADY_EXISTS`, `INVALID_ARGUMENT`, `UNAUTHENTICATED` or `PERMISSION_DENIED` leaves the service running, is retried at the backoff cap without a tight loop (at least 1 s, at most 5 s after the refusal), and its reason is exposed. | runner |
| `L1-HEARTBEAT` | The library heartbeats at `RegisterAck.heartbeat_interval_ms` and an idle instance is never evicted. | runner |
| `L1-SILENT-HUB` | A stream that brings no heartbeat echo for three intervals is dropped and reconnected. | runner |
| `L1-RECONNECT` | After the stream drops, the library reconnects with a backoff whose cap is at most 5 s and the identical `Register`, never stalls, and is registered again within 12 s of a hub restart. | runner |
| `L1-UNARY` | A command and a point query sent through the hub reach their handler, by routing key when one is given, and the reply comes back decoded; a command without a result answers `{}`. | runner |
| `L1-REQUEST-ID` | Every send attempt carries a fresh `Request.id`; no id is reused while a request with it is pending. | runner |
| `L1-TIMEOUT` | `Request.timeout_ms` is 0 unless the caller chose a timeout, and the library gives up locally only after the hub's bound for the request plus 1 s. | runner |
| `L1-ERRORS` | Each `ErrorCode` reaches the caller as its own error; `Error.message` is kept for the codes a handler produces (`ErrorCode.HANDLER_ERROR`, `ErrorCode.UNAUTHENTICATED`, `ErrorCode.PERMISSION_DENIED`, `ErrorCode.INVALID_REQUEST`) and `Error.details` for `ErrorCode.HANDLER_ERROR`; an unknown code reads as `ErrorCode.HANDLER_ERROR`. | runner |
| `L1-NEVER-SENT` | A request never handed to a stream's transport is reported as never sent; one written to a stream that then breaks is reported as outcome unknown. | runner |
| `L1-RETRY` | When the library retries, a command is retried only when its handler never ran, never after `ErrorCode.TIMEOUT`, `ErrorCode.HANDLER_DISCONNECTED` or an unknown outcome; every attempt has a fresh id and sends the remaining budget, never 0, as `Request.timeout_ms`. | runner |
| `L1-ARRIVAL-STREAM` | Replies, parts, ends and control replies go on the stream their request arrived on, and are dropped when that stream is gone. | runner |
| `L1-ONE-TERMINAL` | A handled request gets exactly one terminal message, carrying the id it was forwarded with (`<id>`, `<id>#<n>`, `<id>#0`, `<id>#1`): one `Reply` (unary), one `ReplyEnd` (streaming, subscription target), none after the hub's `Cancel`. | runner |
| `L1-HANDLER-ERRORS` | A handler's failure is a `Reply` with `ErrorCode.HANDLER_ERROR` (a failed nested call included), a payload that does not decode or the wrong mode is `ErrorCode.INVALID_REQUEST`, a type not served is `ErrorCode.NO_HANDLER`; never a dropped stream or a stack trace. | runner |
| `L1-IDENTITY` | Checked through the conformance service: a handler that requires an authenticated caller answers `ErrorCode.UNAUTHENTICATED` to a request without a token or with one that fails validation, `ErrorCode.PERMISSION_DENIED` to an authenticated caller it refuses, and decides before decoding (an anonymous request with a malformed payload gets `ErrorCode.UNAUTHENTICATED`, not `ErrorCode.INVALID_REQUEST`). | runner |
| `L1-PROPAGATION` | A request or event sent while a message is handled carries that message's `correlationId` (when it carries none, its own id: `Request.id` for a request, the event id for an event; a new UUID outside any handling), its `authorization` header (requests only) and a W3C `traceparent` of its trace (the incoming one or a child of it); a call that sets a reserved header (`authorization`, `traceparent`, `tracestate`, `correlationId`, `correlation-id`, any letter case) is refused before anything is sent. | runner |
| `L1-PERMITS` | `Register.initial_permits` is the instance's local capacity; each finished request gives one permit back on its arrival stream, at once at the low-water mark `min(16, initial_permits / 2)`, else batched at 16 or 50 ms. | runner |
| `L1-SHARED` | A query type registered in `Register.shared_query_types` is served by every owning service, and a point query on it reaches one of them. | runner |
| `L1-SCATTER` | A scatter-gather returns every target's answer as parts and ends with the counts of `ReplyEnd`; a target handler cancelled by the hub stops and sends nothing more. | runner |
| `L1-STREAM` | A streaming handler numbers its parts 1, 2, 3, ... with no gap, sends no more parts than its credit, stops on `Cancel`, and ends with `ErrorCode.TIMEOUT` when no credit comes within its bound; a streaming sender refills credit as it reads, sends `Cancel` when it stops, and fails the stream on a gap in `ReplyPart.seq` or a `ReplyEnd.parts` above the parts it received. | runner |
| `L1-SUBSCRIBE` | A subscription returns the initial result then every update, and the sender fails it on a gap in `ReplyPart.seq` or a `ReplyEnd.parts` above the parts it received; a target registers on its `<id>#n` request so no update emitted after the initial result is lost, ends with `ReplyEnd` when its emitter completes, is removed on `Cancel`, and refuses beyond its limit with `ErrorCode.RESOURCE_EXHAUSTED`. | runner |
| `L1-LOST-STREAM` | When a stream is lost, the streaming handlers and subscriptions that arrived on it end, and the streams and subscriptions sent through it fail. | runner |
| `L1-TOKEN` | With a hub in mode `enforce` and an ACL entry for the token, the library registers on every hub with the token in `Register.credentials.token`. That it never logs the token is the library's own test, not the runner's. | runner |
| `L1-JWT` | A JWT registers in `Register.credentials.jwt`, is renewed before it expires and sent once per renewal as `ClientMessage.credentials`; after an `UNAUTHENTICATED` close the next stream uses a newly fetched token. | runner |
| `L1-MTLS` | A client certificate session reconnects with the renewed certificate before `notAfter`, and the hub's close at `notAfter` is reconnected at the normal backoff, not handled as a refusal. | runner |
| `L1-TLS` | The library connects over TLS with an operator-chosen CA and server name. | runner |
| `L1-HUBS` | The library holds one stream per hub with the identical `Register`, knows each hub by `RegisterAck.hub_id`, and keeps one stream per `hub_id` when two targets answer the same id. | runner (fake hubs; also two real hubs when given) |
| `L1-HUB-ROUTING` | Unkeyed requests go round-robin over the acknowledged hubs; a request with a routing key goes to the live hub with the highest rendezvous score of [protocol.md](protocol.md#several-hubs) (unsigned comparison, ties to the smaller hub id, compared as bytes: hub ids are ASCII), checked with its test vectors and two hubs. | runner (two fake hubs) |
| `L1-HUB-PERMITS` | Each hub gets `ceil(max / N)` initial permits; when a hub goes, every live stream is topped up with `Permits.count` and `Permits.grant`; permits are never revoked. | runner (two fake hubs) |
| `L1-HUB-FAILOVER` | A request never handed to a stream's transport goes to another hub with the same id; a unary `ErrorCode.NO_HANDLER` from one hub is tried on the others within the remaining timeout, in the order the request chose its first hub by (rendezvous for a keyed request, round-robin otherwise). | runner (two fake hubs) |
| `L1-STATUS` | `InstanceStatus` goes at least every 5 s on every stream (extra reports are allowed), with the acknowledged hub ids and the handlers in flight. | runner |

## Level 2: Events

| Id | Check | Proved by |
|---|---|---|
| `L2-EVENT-STORE-KIT` | The event-store add-on passes the kit's required checks: `headers_round_trip`, `same_key_arrives_in_publish_order`, `every_processor_gets_every_event`, `instances_share_a_processor`, `a_joining_instance_announces_its_first_assignment` (a new subscription's first event is an assignment, possibly empty, within 10 s of joining), `an_instance_left_without_segments_closes_its_change`, `unacked_delivery_is_redelivered`, `redelivered_after_commit_is_skipped`, `paused_subscription_receives_nothing_and_resumes_in_place`. | kit |
| `L2-STORE-KIT` | The message-store add-on passes the kit's outbox and processed-event checks: `appended_entry_is_claimed_in_created_seq_order`, `outbox_rejects_a_payload_that_is_not_a_json_object`, `pending_counts_entries_neither_sent_nor_failed`, `rolled_back_transaction_leaves_no_outbox_entry`, `rolled_back_handler_leaves_no_processed_marker`, `processed_marker_records_once`, `concurrent_relays_publish_each_entry_once`, `expired_lease_is_reclaimed`, `purge_removes_only_sent_before`. | kit |
| `L2-HEADERS` | Every published event carries the seven headers of [messages.md](messages.md#event-headers) with the content given there. | runner, not checked yet |
| `L2-OUTBOX` | An event published inside the service's transaction is appended to the outbox in it, is relayed only if that transaction commits, and events of one key published by one instance reach the event store in publish order while one relay sends the outbox (with several relays, batches claimed by different relays are not ordered against each other). | runner, not checked yet |
| `L2-CONSUME` | Each delivered event runs its handlers and records its processed-event marker in one transaction, is acknowledged only after the commit, is skipped (and acknowledged) when its marker exists, and an event type no handler handles is acknowledged without running anything. | runner, not checked yet |
| `L2-NO-ADD-ON` | A service with only command, query and subscription-query handlers starts without an event store and a message store; publishing an event, an event handler or a saga without them fails at startup with a message naming the missing add-on. | runner, not checked yet |

## Level 3: Processors

| Id | Check | Proved by |
|---|---|---|
| `L3-EVENT-STORE-KIT` | The event-store add-on passes the kit's capability checks: for each capability it declares `replay_from_earliest_redelivers_history` (`replay`), `lag_counts_unacked` (`lag`), `dead_letter_source_receives` (`native-dead-letter`), `search_finds_by_type_key_and_correlation`, `search_stops_at_bounds`, `tail_streams_new_events`, `browser_never_commits_a_position` (`browse`); for each it does not, `admin_without_replay_is_unsupported`, `lag_unknown_without_capability`, `no_browser_without_capability`. | kit |
| `L3-STORE-KIT` | The message-store add-on passes the kit's processor checks: `delete_markers_removes_only_the_range`, `dead_letters_sequence_per_key`, `dead_letter_parked_inside_rolled_back_transaction_is_kept`, `dead_letter_deleted_in_a_transaction_goes_with_it`, `control_lock_is_exclusive_until_lease_expires`, `pause_state_round_trips`, `replay_ranges_round_trip`, `processor_control_write_inside_rolled_back_transaction_is_kept`. | kit |
| `L3-PROCESSORS` | Handlers run in named processors (`default` and names matching `[a-z0-9][a-z0-9-]{0,47}`), each with its own subscription `<service>.<processor>` and markers `processor:<name>:<eventId>`; one event type in two processors reaches both, and a failure in one does not affect the other. | runner, not checked yet |
| `L3-STATUS` | Every status tick carries one `ProcessorStatus` per started processor, filled as [protocol.md](protocol.md#processor-status) says, with the event store's name and capabilities, and the whole list each time. | runner, not checked yet |
| `L3-CONTROL` | A `ControlRequest` is handled off the read loop, one per processor at a time, and answered with exactly one `ControlReply` with its `ControlReply.control_id`, on its arrival stream. | runner, not checked yet |
| `L3-PAUSE` | A pause persists in the message store and stops delivery without leaving the subscription (`ProcessorState.PROCESSOR_PAUSED`); a resume delivers from where it stopped; an instance that missed the request converges from the store within one poll. | runner, not checked yet |
| `L3-RESET` | A reset follows prepare, execute, finish: the lock and its lease, `ControlRefusal.CONTROL_REFUSAL_LOCKED`, `ControlRefusal.CONTROL_REFUSAL_NOT_PREPARED` for an ended operation or a late renewal, `ControlRefusal.CONTROL_REFUSAL_SUBSCRIBERS_ACTIVE`, the reset handlers before any marker or position moves, an expired lease resuming the instance by itself, and `ControlRefusal.CONTROL_REFUSAL_UNSUPPORTED` without `replay`. | runner, not checked yet |
| `L3-REPLAY` | Records below a segment's `SegmentStatus.replay_until` run the processor's handlers except those marked not to replay, never the sagas; the reset deleted the processor's markers of the range; the range closes once the committed position reaches it. | runner, not checked yet |
| `L3-DEAD-LETTERS` | A record that exhausts its attempts is parked (mode `collection`), sent to the event store's dead-letter destination (`event-store`) or logged and skipped (`log`); letters are sequenced per key, and list, retry, retry-all and discard work through `ControlRequest` with the outcomes of hub.proto. | runner, not checked yet |

## Level 4: Sagas

| Id | Check | Proved by |
|---|---|---|
| `L4-STORE-KIT` | The message-store add-on passes the kit's saga checks: `external_call_idempotency_returns_first_result`, `saga_ports_round_trip`, `saga_dispatch_store_refuses_an_event_the_outbox_would_refuse`, `due_deadline_is_claimed_once_until_its_lease_passes`, `two_schedulers_claim_each_due_deadline_once`, `an_empty_deadline_correlation_id_reads_as_absent`, `dispatch_hands_out_each_saga_in_seq_order`, `two_relays_never_hold_one_saga_lease`, `concurrent_notice_claims_return_each_notice_once`, and the two concurrent writes of one saga (Rust `two_transactions_starting_one_saga_key_leave_one_live_saga` and `two_transactions_updating_one_saga_version_commit_once`; Kotlin `concurrentStartsOfOneSagaKeyLetOneWin` and `concurrentUpdatesOfOneSagaLetOneWin`). | kit |
| `L4-SAGA-DISPATCH` | A saga's commands and events are recorded in its transaction and sent only after it commits, in order per saga, at least once; a command carries `idempotency-key` (`<sagaId>:<seq>`) and `saga-id`, and no `authorization`. | runner, not checked yet |
| `L4-SAGA-ONCE` | A redelivered event is applied to a saga once (marker `saga:<type>:<eventId>`), one event at a time per saga instance. | runner, not checked yet |
| `L4-COMMAND-FAILED` | A saga command that fails for good comes back to the saga as the local event SagaCommandFailed, never published to the event store. | runner, not checked yet |
| `L4-DEADLINES` | A deadline fires once at its due time over every instance, and a cancelled one never fires. | runner, not checked yet |
| `L4-ADAPTER-MARKERS` | `Error.details` of `{"snodra":"retryable"}` and `{"snodra":"unknown-outcome"}` are written by an adapter's failure and read by the saga relay, also across the hub. | runner, not checked yet |

The kits and the runner check behaviour a library can show from outside. The full contract of levels 3 and 4 (the
reset steps, the dead-letter document, the saga dispatch, retries and failure notice, the saga storage) is written in
[protocol.md](protocol.md), [messages.md](messages.md), [writing-a-library.md](writing-a-library.md) (levels 3 and 4),
[event-store-add-ons.md](event-store-add-ons.md) and [message-store-add-ons.md](message-store-add-ons.md).

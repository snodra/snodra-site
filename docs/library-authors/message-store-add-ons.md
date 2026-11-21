# Writing a message-store add-on

This page is for you if you write a message-store add-on, for an existing Snodra library or for a new one, in any
language: the piece that keeps everything the library stores (the outbox, the processed events, dead letters, processor
control, external calls, sagas) in the service's own database. After reading it you know the one rule an add-on cannot
break, the stores it implements and what each operation guarantees, and the conformance checks it must pass. The event
store, which reads what the outbox relays, is [event-store-add-ons.md](event-store-add-ons.md).

## The rule

**The outbox entry and the processed-event record commit in the same transaction as the service's own data**, or the
dual-write problem the outbox solves comes back: a service that writes its data and publishes its event as two separate
steps loses the event when it stops between them, or publishes one whose data never committed. So a
message-store add-on is the service's own database and joins the service's own transaction; Snodra never needs a
database of its own, and the library cannot choose the store for the service.

- One store per service, the service's own database. A shared database holds the instances of **one** logical
  service: processed-event markers, processor control, dead-letter key blocking and the claims of deadlines and notices
  carry no service name, so different services use separate databases or schemas.
- **No store is valid** for a service with only command, query and subscription-query handlers. Publishing an event,
  handling one, or declaring a saga without a store fails at startup with a message naming the missing add-on *(the
  Rust library refuses event handlers and sagas without a store when the application is built, and a publish without
  a message store or an event store at the first publish, since its builder cannot know that a service publishes)*.
- Store and event store are independent: any store works with any event store.
- Order per key holds for the events one instance publishes while one relay sends the outbox; across instances it
  never did. With several relays on one outbox, entries of one key in batches claimed by different relays may be
  published out of order, even entries one instance published: a relay claims the oldest pending entries, but another
  relay holding the next batch may send it first. A service that needs the order per key of what one instance
  publishes runs one relay on its outbox (Kotlin `snodra.messaging.outbox.enabled`, Rust `SNODRA_OUTBOX_ENABLED`, off
  on the other instances).
- Payloads cross the interfaces as JSON bytes (or JSON text where the stored contract is text), never as a database's
  own document format; times as epoch milliseconds. An outbox payload is a JSON object whose integers fit a signed
  64-bit integer: what the narrowest store (MongoDB) holds, so every store refuses the same inputs. Besides that, the shared check of both libraries
  (Rust `store::check_outbox_payload`, Kotlin `checkOutboxPayload`) refuses a payload **deeper than 100**, depth counted
  as MySQL's `JSON_DEPTH` counts it (a scalar or an empty array or object is 1, a non-empty one is 1 + its deepest member:
  `{}` is 1, `{"a":1}` is 2, `{"a":[1]}` is 3); a number no double holds (`1e400`; one that merely rounds, `1e-400`, is
  fine); a lone surrogate escape (`"\ud800"`), in a value or a name (a pair is fine); a leading byte order mark; and bytes
  that are not UTF-8.
  The depth bound is what every store keeps: MySQL holds at most 100 nested arrays and objects, so the bound is MySQL's
  exact limit for a document ending in an empty array or object, and one stricter than MySQL for a document whose
  deepest leaf is a scalar (MySQL stores 100 containers around a scalar, `JSON_DEPTH` 101; the contract refuses it).
  The other refusals are what a Rust consumer (serde_json) cannot decode.
- Times a store stamps itself (an entry's sending, a lease) come from the application's clock, never the database's,
  so a lease means the same on every instance whatever the database's clock says.

## The stores

An add-on implements every store, not only the outbox: a service without one database must not need it for its dead
letters or sagas. The official interfaces are `snodra_messaging::store` (Rust; `store::MessageStore` gathers them) and
`com.damoreira.snodra.messaging.store` (Kotlin); their meaning is the contract.

| Store | Operations | In the caller's transaction |
|---|---|---|
| Transactions | begin, commit, abort (never fails); a plain "no transaction" for reads and writes outside one; join the caller's transaction when one is active | - |
| Outbox | append in the caller's transaction (or on its own); claim the next batch in `(created_at, seq)` order under a lease; mark sent, mark an attempt failed, mark failed for good; purge sent entries after the retention; count the pending entries and give the oldest one's time | append: yes |
| Processed events | record a marker in the handler's transaction (false when its id exists: a duplicate); tell whether a marker exists; delete a processor's markers in replay ranges; purge after the retention | record: yes |
| Dead letters | park, find the head letter of a key and an earlier letter, list, summarise, count, get, delete, delete in a retry's transaction, record a failed retry; sequenced per (processor, key) | only a retry's delete |
| Processor control | per processor: the pause state, the reset lock with its lease (take, renew, release, expire) and the replay ranges | no: each write commits on its own |
| External calls | the idempotency records of external calls and ingress: insert (the first call of a key wins), find, take a lapsed call over, give it up, succeed, fail, mark unknown, reset | no: a rolled-back handler never forgets a call that happened |
| Saga ports | the sagas, their dispatch entries (the saga-side outbox) and its leases, deadlines, failures and markers ([Sagas and deadlines](../messaging/index.md#sagas-and-deadlines)) | yes |

The operations' guarantees, each proved by a kit check ([The conformance kit](#the-conformance-kit)):

- **Outbox.** An entry is *pending* until it is sent or failed. A claim returns at most `limit` pending entries, now held
  by the claimer until its lease passes: those nobody holds, those whose holder's lease has passed, and those the
  claimer holds already; never an entry another claimer holds. `(created_at, seq)` is the only order (`seq` is the
  appending process's counter, breaking ties): an entry whose send failed is retried before the later ones, so order
  per key holds within one relay (two relays' batches are not ordered against each other). A failed attempt counts and keeps the entry pending; an entry given up is never claimed again nor
  purged. A payload that is not a JSON object with integers that fit in a signed 64-bit integer is refused. A store may
  wake the relay on every committed append instead of letting it poll.
- **Processed events.** A marker id records once. A library handles one delivered event in two stages: **stage 1**
  runs the processor's event handlers, **stage 2** the sagas (in `default` only), with markers and transactions of
  their own ([writing-a-library.md, Level 4](writing-a-library.md#applying-an-event)).
  A **stage-1 marker**{#stage-1-marker} is the marker `processor:<name>:<eventId>` that stage 1 records in the same
  transaction as the handlers' effects (`<name>` the processor, `<eventId>` the event's id, or its dedupe id for an event dispatched inside
  the service), so a redelivery whose
  stage 1 committed skips the handlers. A stage-1 marker of a delivered event (one the processor's subscription
  delivered, or a dead letter's retry) also records its processor, source, segment and position, so a reset deletes
  exactly the markers of its replay range; markers without a position (a stage-1 marker of an event dispatched inside
  the service, such as a translated partner event, and every saga, ingress and failure-notice marker) are never deleted
  by a reset.
- **Dead letters.** A letter's id is `<processor>:<source>:<segment>:<position>`, so parking a redelivered record finds
  the first letter. The head of a key is the earliest position among its letters that are not `INVALID`. Every
  operation is a write of its own, but a retry deletes its letter in the record's transaction: the letter goes only
  if the retry commits.
- **Processor control.** A reset lock is held by one operation until its lease passes; only its holder releases it,
  and an expiry clears it only past the lease. A pause does not touch the lock and the lock does not touch the pause.

**Identifiers the stores hold**, the same in every add-on and both libraries: markers `processor:<name>:<eventId>`
([stage 1](#stage-1-marker) of a processor), `saga:<sagaType>:<eventId>`, `ingress:<source>:<key>`, `failed:<sagaId>:<seq>`; dead letters
as above; saga dispatch entries `<sagaId>:<seq>` (also the command's `idempotency-key`).

## The conformance kit

One suite every message-store add-on runs, in the library's test module: Rust
`snodra_messaging::store::conformance::run_store_conformance(store)` (cargo feature `testing`, on a multi-thread
runtime: some checks race two tasks; the store must be the kit's alone while it runs), Kotlin
`com.damoreira.snodra.messaging.test.store.MessageStoreConformanceTest` in `snodra-messaging-test` (subclass it; `store()`
returns a store over empty state, its schema ready; transactions are Spring's). Every check is public, so a failing one
can be run by itself. What each asserts:

| Check | Asserts |
|---|---|
| `appended_entry_is_claimed_in_created_seq_order` | entries are claimed in `(created_at, seq)` order however they were appended; a claim skips what another owner holds, gives an owner back what it holds already and returns every field as appended; a retried entry keeps its place and counts the attempt |
| `outbox_rejects_a_payload_that_is_not_a_json_object` | anything but a JSON object whose integers fit in a signed 64-bit integer is refused, and so are a depth over 100 (`JSON_DEPTH`), `1e400`, a lone surrogate escape, a leading byte order mark and bytes that are not UTF-8, appended on its own or in a transaction, and nothing is appended; a depth-100 payload is appended and claimed back equal |
| `pending_counts_entries_neither_sent_nor_failed` | the pending count counts the entries neither sent nor failed, held or not, and the oldest pending time is the oldest of them |
| `rolled_back_transaction_leaves_no_outbox_entry` | an entry appended in a rolled-back transaction never reaches the relay; one in a committed transaction does |
| `rolled_back_handler_leaves_no_processed_marker` | a handler's rolled-back transaction leaves neither its marker nor the events it published: a redelivery handles the event again |
| `processed_marker_records_once` | a marker records once until a purge past its time removes it; a purge keeps the markers recorded after its bound |
| `delete_markers_removes_only_the_range` | a reset deletes the [stage-1 markers](#stage-1-marker) of its processor in its ranges and nothing else: no other position, segment, source or processor, no marker without a position |
| `concurrent_relays_publish_each_entry_once` | two relays claiming one outbox at once: every entry is claimed by exactly one of them, and each claims some while the other holds its first batch |
| `expired_lease_is_reclaimed` | a claimer that crashes holds its entries until its lease runs out; then another relay claims them, in order, with the attempts counted |
| `purge_removes_only_sent_before` | a purge removes the entries sent before its bound and nothing else; a failed entry is never claimed again |
| `dead_letters_sequence_per_key` | letters are sequenced per (processor, key): the head is the lowest position that is not `INVALID`, an earlier letter blocks a retry, a second park of a record finds the first letter, a failed retry updates the letter in place |
| `dead_letter_parked_inside_rolled_back_transaction_is_kept` | a letter commits on its own: parked while a transaction that is then rolled back is open, it stays |
| `dead_letter_deleted_in_a_transaction_goes_with_it` | a retry deletes its letter in the record's transaction: a rollback keeps the letter, a commit removes it |
| `control_lock_is_exclusive_until_lease_expires` | a reset lock is held by one operation until its lease passes; another is refused with the holder; the holder renews; only the holder releases it |
| `pause_state_round_trips` | a pause round-trips with who paused and when, idempotently; a resume clears both; pause and lock are independent |
| `replay_ranges_round_trip` | replay ranges round-trip in order; a removal takes exactly that range, once; a replacement replaces them all |
| `processor_control_write_inside_rolled_back_transaction_is_kept` | a processor-control write commits on its own, whatever happens to an open transaction |
| `external_call_idempotency_returns_first_result` | the first call of a key wins: a repeat finds its record and, once it succeeded, the first reply; a lapsed call is taken over or given up only when the record is still the one read |
| `saga_ports_round_trip` | each saga port reads back what it wrote in a committed transaction; an aborted one leaves nothing |
| `saga_dispatch_store_refuses_an_event_the_outbox_would_refuse` | a saga's event entry with a payload the outbox would refuse is refused inside the saga's transaction, and nothing of the attempt commits |
| `due_deadline_is_claimed_once_until_its_lease_passes` | a due deadline is claimed by one scheduler at a time, earliest first, until its claim passes; one not due, fired or cancelled never is |
| `two_schedulers_claim_each_due_deadline_once` | two schedulers claiming at once: every due deadline goes to exactly one of them |
| `an_empty_deadline_correlation_id_reads_as_absent` | a deadline written with an empty correlation id reads back without one, from the lookup of a scheduled deadline and from the claim of due ones |
| `dispatch_hands_out_each_saga_in_seq_order` | a saga's pending dispatch entries come in `seq` order, the sagas whose first entry is due oldest first; a saga's lease is held by one relay; an entry dispatched in a rolled-back transaction stays pending; a failed one carries its outcome and its failure notice |
| `two_relays_never_hold_one_saga_lease` | two relays claiming the dispatch leases of the same sagas at once: each saga's lease goes to exactly one of them |
| `concurrent_notice_claims_return_each_notice_once` | two relays claiming the due failure notices of saga commands at once, each until none is left: every notice goes to exactly one of them, once |
| `two_transactions_starting_one_saga_key_leave_one_live_saga` | two transactions start a saga of one start key at once, both writing before either commits: one commits, the other fails with the store's retryable conflict instead of waiting for the first to end, and one live saga remains |
| `two_transactions_updating_one_saga_version_commit_once` | two transactions update one version of a saga at once: one commits, the other fails with the retryable conflict |

Which checks prove which feature level: [feature-levels.md](feature-levels.md) (`L2-STORE-KIT`, `L3-STORE-KIT`,
`L4-STORE-KIT`).

### Check names in both libraries

These pages name every check by the Rust kit's name. The Kotlin kits hold the same checks in camelCase
(`appended_entry_is_claimed_in_created_seq_order` is `appendedEntryIsClaimedInCreatedSeqOrder`), except these:

| Rust kit | Kotlin kit |
|---|---|
| `outbox_rejects_a_payload_that_is_not_a_json_object` | `outboxPayloadMustBeAJsonObject` |
| `pending_counts_entries_neither_sent_nor_failed` | `oldestPendingIsTheOldestEntryNeitherSentNorFailed` |
| `dead_letter_deleted_in_a_transaction_goes_with_it` | part of `deadLettersSequencePerKey` |
| `saga_dispatch_store_refuses_an_event_the_outbox_would_refuse` | `sagaEventTheOutboxWouldRefuseIsNotRecorded` |
| `due_deadline_is_claimed_once_until_its_lease_passes` | `dueDeadlinesAreClaimedOnceUntilTheirLeaseExpires` |
| `two_schedulers_claim_each_due_deadline_once` | `concurrentDeadlineClaimsReturnEachDeadlineOnce` |
| `dispatch_hands_out_each_saga_in_seq_order` | `sagaDispatchEntriesAreRelayedInOrderPerSaga` and `sagaDispatchLeaseIsExclusiveUntilItExpires` |
| `two_relays_never_hold_one_saga_lease` | `concurrentLeaseClaimsGrantOneOwner` |
| `two_transactions_starting_one_saga_key_leave_one_live_saga` | `concurrentStartsOfOneSagaKeyLetOneWin` |
| `two_transactions_updating_one_saga_version_commit_once` | `concurrentUpdatesOfOneSagaLetOneWin` |
| `an_empty_deadline_correlation_id_reads_as_absent` | none yet (the Kotlin stores follow the rule; no kit check names it) |

The checks that race two tasks or threads (two relays on one outbox, two schedulers, two relays on one saga's lease,
two relays on the failure notices, two transactions on one saga) are store-neutral: they hold on every store, the in-memory one included. One list of
names for both libraries is not settled yet.

## The reference: the in-memory message store

Both libraries ship an in-memory message store (name `memory`) that implements every store with the semantics of the
database add-ons and passes the kit: read it first.

- Real transactions: what a transaction writes is seen by others only at its commit and is gone after a rollback; two
  live transactions writing one record conflict, which the library retries like a database's write conflict.
- Claims and leases are atomic and follow the application's clock; every committed append wakes the relay.
- Not durable and one process only: a startup warning says so. Rust: `snodra_messaging::store::memory`; Kotlin: in the
  core library, selected with `snodra.messaging.store.type: memory`.
- Under another transaction manager (Kotlin: the service's own database with its JDBC or JPA manager), an event
  published in that transaction is appended when the transaction completes with a commit, never after a rollback: after
  the commit, not atomically with it. In Rust a transaction that ended counts as none, so a write with it commits at
  once.

The MongoDB add-on (both libraries) keeps the libraries' collections (`outbox`, `processed_events`, `dead_letters`,
`processor_control`, `external_calls`, the saga collections) and needs a replica set for its transactions. **A reader
must accept the absence of every optional field**: the Rust store leaves out a field it has no value for, where the
Kotlin store may write it, so a third-party store sharing the collections reads a missing optional field as none. The
fields the Rust store omits: `sagas` `startKey`, `endedAt`; `saga_dispatch` `routingKey`, `dispatchedAt`,
`nextAttemptAt`, `failedAt`, `failureReason`, `failureMessage`, `noticePending`, `noticeAttempts`, `noticeNextAt`;
`deadlines` `payload`, `payloadType`, `claimedBy`, `claimedUntil`, `finishedAt`, `correlationId`; `outbox` `owner`,
`leaseUntil`; `dead_letters` `key`, `eventId`, `eventType`, `payload`, `payloadBinary`, `blockedBy`, `replay` (absent is
false); `external_calls` `reply`, `error`, `leaseUntil`, `owner`. A deadline's empty correlation id is written as no
`correlationId` field by both libraries. The SQL
add-on (Kotlin `snodra-messaging-jdbc`, Rust `snodra-messaging-sqlx`) keeps them in tables whose layout both libraries
share, below.

The SQL layout is specified on this page; the MongoDB collections and their document shapes are not, yet. Today they
are defined only by the official MongoDB add-ons, which a store sharing the collections reads as its reference: the
Kotlin module
[`snodra-messaging-mongo`](https://github.com/snodra/snodra-messaging/tree/main/snodra-messaging-mongo) and the Rust
crate [`crates/snodra-messaging-mongo`](https://github.com/snodra/snodra-messaging-rs/tree/main/crates/snodra-messaging-mongo).
A page specifying them is planned.

## The SQL layout

The SQL add-ons of both libraries share one layout, so instances in either language share a database. A third-party
SQL add-on that shares a database with them follows it.

- **The schema files** are the normative reference, published with this page:
  [`sql/v1/postgresql/V1__snodra.sql`](sql/v1/postgresql/V1__snodra.sql) and
  [`sql/v1/mysql/V1__snodra.sql`](sql/v1/mysql/V1__snodra.sql). V1 is frozen: SHA-256
  `0b2d179a18580092cd7622d11e46451a08b64fad7d6d585450a0919f9148ca6a` (PostgreSQL) and
  `f6e28f7c12c0e7db148b534c6ac9d04e5a375bd3b873d63a1c8080707af0cf31` (MySQL), checked by this site's
  `scripts/check-library-spec.sh`. They are byte-for-byte copies of `db/snodra/postgresql/V1__snodra.sql` and
  `db/snodra/mysql/V1__snodra.sql` in the resources of the Kotlin module `snodra-messaging-jdbc`, which applies them;
  the Rust crate `snodra-messaging-sqlx` embeds the same bytes and pins both checksums in a test.
- **Twelve tables**, prefixed `snodra_`: `snodra_schema` (the version), `snodra_outbox`, `snodra_processed_events`,
  `snodra_dead_letters`, `snodra_processor_control`, `snodra_external_calls`, `snodra_sagas`,
  `snodra_saga_associations`, `snodra_saga_dispatch`, `snodra_saga_dispatch_leases`, `snodra_deadlines`,
  `snodra_saga_failures`.
- **Versions are additive**: a later change is V2, V3 in the same history, and code at version n accepts a database at n
  or later. Applied at startup by default under a database lock; with that off, the startup refuses a database below
  V1. Run with Flyway, the library's files keep a history table of their own (`snodra_schema_history`), apart from the
  application's migrations.
- **Hashes**: a value without a bound that must be unique or looked up (a processed-event marker id, an idempotency
  key, a saga failure id, a saga start key, an association, a dead letter's record key) goes through a `CHAR(64)`
  column holding the lowercase hex SHA-256 of its UTF-8 bytes (for an association: the key, a 0x00 byte, the value);
  the value is kept whole beside it, and every lookup compares the hash.
- **Bounds**, in characters, checked in code before any write, never truncated: processor 64, source 255, segment 128,
  position 128, type and saga or deadline names 255, library ids 255, dead-letter id 578 (the four parts and three
  colons). A longer value is refused with an error naming the field and its length; free text (errors, failure
  messages) is cut at 16 KiB of UTF-8 on a character boundary. The character U+0000 is refused in every text value and
  JSON string (PostgreSQL's `jsonb` cannot hold it), except in a dead letter's payload, which is then kept as bytes.
- **Empty as absent**: a deadline's `correlation_id` holding an empty text reads as none (the deadline's work then
  correlates on the deadline's own id), so a row one library wrote with an empty text and the other with none read the
  same. The rule holds on every store (on MongoDB: no field, and a reader accepts a missing one; kit check
  `an_empty_deadline_correlation_id_reads_as_absent`).
- **JSON or text**: the outbox payload and the header maps are `jsonb` (PostgreSQL) or `JSON` (MySQL); the saga state,
  the saga dispatch, deadline and failure payloads, the external calls' replies and errors and a dead letter's payload
  are text, so they read back exactly as written.
- **Databases**: PostgreSQL 13 or later; MySQL 8.0.17 or later on InnoDB with the tables in `utf8mb4_0900_bin` and a
  STRICT `sql_mode`; a connection pool of at least two connections.
- **Transactions**: the store joins the service's transaction; a write outside one, or after it ended, runs in a short
  transaction of its own; every transaction the store runs on its own (claims, dead letters, processor control, the
  purge) runs at READ COMMITTED. Claims take `SELECT ... FOR UPDATE SKIP LOCKED` in `(created_at, seq)` order; two
  writers of one saga never wait for each other to end (`NOWAIT`, an advisory lock on PostgreSQL, a one-second lock
  wait on MySQL): the second fails with the retryable conflict.
- **Retention and wake-up**: a purge task (every minute by default) removes what the retentions let go; on PostgreSQL
  an append's transaction sends `NOTIFY` on `snodra_outbox` and the relay listens on a connection of its own (it can be
  turned off); MySQL polls.

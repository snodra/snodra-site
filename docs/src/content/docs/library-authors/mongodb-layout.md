---
title: "MongoDB layout"
---

This page is for you if you write a message-store add-on on MongoDB, or anything else that reads or writes the
collections of one: the collections, every document field with its BSON type, every index, and the operations whose
atomicity two libraries sharing a database rely on. A Kotlin and a Rust instance of one service already share one
MongoDB database; an add-on in another language that follows this page shares it with them. What the stores mean and
which conformance checks prove them is [message-store-add-ons.md](/docs/library-authors/message-store-add-ons/); the SQL layout is
[there too](/docs/library-authors/message-store-add-ons/#the-sql-layout).

The page states what the two official add-ons both do: the Kotlin module `snodra-messaging-mongo` and the Rust crate
`snodra-messaging-mongo`. Where they do not yet do the same, the last section,
[Where the two add-ons differ today](#where-the-two-add-ons-differ-today), says what each does.

## The rules for every collection

- **Ten collections**, in the service's own database (Kotlin: the database of the application's Spring Data MongoDB template;
  Rust: the database the application passes to the store): `outbox`, `processed_events`, `dead_letters`,
  `processor_control`, `external_calls`, `sagas`, `saga_dispatch`, `saga_dispatch_leases`, `deadlines`,
  `saga_failures`. The names are fixed: no prefix, no setting changes them. One database holds the instances of one
  logical service ([the rule](/docs/library-authors/message-store-add-ons/#the-rule)).
- **A replica set.** The store's transactions are MongoDB multi-document transactions on a client session, which
  MongoDB only runs on a replica set (a single-node replica set is enough). Which writes join a transaction:
  [Transactions](#transactions).
- **The schema is the indexes.** At startup the store creates every index below, idempotently, with
  `createIndexes` (Kotlin `snodra.messaging.store.init-schema`, Rust `SNODRA_STORE_INIT_SCHEMA`, both `true` by
  default). Creating the indexes also creates the collections, before any transaction writes to them: a transaction
  must not be the first write of a collection. Neither add-on changes an index that exists, and MongoDB refuses an
  index under an existing name with other options: give every instance sharing a database the same retentions
  ([Retentions](#retentions)).
- **Index keys are ascending** (`1`, an int) everywhere, and every index has the name given in its table. Create
  them under these names: MongoDB refuses a second index with the same keys and the same options under another name.

### Types and values

Types below are the aliases MongoDB's `$type` uses: `string`, `int` (32-bit), `long` (64-bit), `double`, `bool`,
`date`, `object` (an embedded document), `array`, `binData`, `null`.

| What | How it is stored |
|---|---|
| `_id` | A `string` in every collection; never an ObjectId, never a compound document. Its form is given per collection. |
| Times | A `date` (UTC milliseconds since the epoch): never a string, never a number. A time with a finer precision is cut to the millisecond. Times the store stamps itself (a send, a lease) come from the application's clock, never the database's (`$currentDate` and `$$NOW` are not used). |
| Integers | `int` or `long` exactly as each field's table says: counters (`attempts`, `noticeAttempts`) are `int`; `seq` and a saga `version` are `long`. Never a `double`: the Rust add-on cannot read a `double` where it expects an integer. |
| UUIDs | The 36-character lowercase text form, as a `string`; never `binData`. Outbox entry, saga and deadline ids are random (version 4) UUIDs in both libraries. |
| Enums | A `string`: the value's upper-case name, listed with each field. |
| JSON text | A `string` holding the JSON exactly as the library encoded it: a saga's `state`, the dispatch, deadline and failure `payload`, an external call's `reply` and `error`, a dead letter's `payload`. It reads back byte for byte. |
| The outbox payload | An `object`: the event's JSON object converted to BSON ([outbox](#outbox)). The only place a `double` appears. |
| Headers | An `object` whose values are all `string` (an empty string is a value). The order of its fields carries no meaning. |
| Segments and positions | See [Segments and positions](#segments-and-positions). |

### Absent, null and extra fields

- **An optional field without a value is absent**, never `null`, except where a table says the field is written
  as `null` (the `processor_control` document, and three outbox fields in one add-on: see the differences).
- **A reader treats `null` and absent the same.** Both add-ons query "no value" as `{field: null}`, which matches
  both, and so must a third add-on.
- **A reader ignores fields it does not know.** Both add-ons read by field name and ignore the rest, including the
  `_class` field that documents written by older versions of the Kotlin library carry. Write no `_class`.
- **The order of a document's fields carries no meaning.** No query compares a whole embedded document by its
  order: the `$pull` of a replay range matches it field by field.

### Segments and positions

An event store's segment and position are opaque strings. They are stored in the fields `partition` (the segment)
and `offset` (the position), or `from` and `until` in a replay range, and `topic` holds the source:

- a segment that is a canonical decimal `int` (`"3"`, not `"03"`, `"+3"` or `"2147483648"`) is stored as that `int`;
- a position that is a canonical decimal `long` (`"41"`, not `"041"` or a number above 2^63-1) is stored as that `long`;
- anything else is stored as the `string` itself.

A reader turns an `int` or `long` back into its decimal text. Queries compare positions as MongoDB compares the stored
values: numbers by value, strings by their bytes. This keeps documents written before the event store became an
add-on (Kafka partitions and offsets) readable without a migration.

## outbox

One document per event appended to the outbox, relayed to the event store afterwards.

```json
{
  "_id": "1b4e28ba-2fa1-41d2-883f-0016d3cca427",
  "type": "orders.OrderPlaced",
  "key": "order-7",
  "headers": {"correlationId": "corr-7", "userId": "u-1"},
  "payload": {"orderId": "order-7", "total": 1230},
  "createdAt": {"$date": "2026-11-03T10:00:00Z"},
  "seq": {"$numberLong": "42"},
  "attempts": 0
}
```

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | The entry's id, a random UUID. |
| `type` | `string` | always | The event's type name. |
| `key` | `string` | optional | The event's key; absent (or `null`) for an event without one. |
| `headers` | `object` of `string` | always | The headers the event is published with ([messages.md](/docs/library-authors/messages/)): `correlationId`, `userId` (empty when there is no user) and the trace context when there is one. |
| `payload` | `object` | always | The event's JSON object as a BSON document (below). |
| `createdAt` | `date` | always | When the entry was appended. |
| `seq` | `long` | always | The appending process's counter: breaks `createdAt` ties, so the order per key holds. |
| `attempts` | `int` | always | Failed sends so far; `0` when appended. |
| `sentAt` | `date` | optional | When it was relayed. Absent (or `null`): not sent. |
| `failedAt` | `date` | optional | When it was given up on. Absent (or `null`): not given up. |
| `owner` | `string` | optional | The relay holding the entry (a random id per relay instance). Absent: never claimed. |
| `leaseUntil` | `date` | optional | Until when `owner` holds it. |

**The payload.** The JSON object of the event becomes a BSON document field for field, in the order written: an object
becomes an `object`, an array an `array`, a string a `string`, `true` and `false` a `bool`, `null` a `null`, a number
with a fraction or an exponent a `double`, an integer an `int` or a `long` (which one differs: see the differences).
A payload the shared payload contract refuses is refused before anything is written: anything but a JSON object, an
integer outside the signed 64-bit range, a depth over 100, a number no double holds, a lone surrogate escape, a leading
byte order mark, bytes that are not UTF-8 ([the payload contract](/docs/library-authors/message-store-add-ons/#the-rule) has the exact
rules). Both add-ons interpret MongoDB
Extended JSON keywords in the payload (an object such as `{"$numberLong": "5"}` becomes that BSON value), so an event
must not use them as field names. To relay an entry, the document is turned back into compact relaxed Extended JSON:
the value is the same, the text need not be (`12.30` comes back as `12.3`).

| Index | Keys | Options |
|---|---|---|
| `sentAt_1_createdAt_1_seq_1` | `sentAt: 1, createdAt: 1, seq: 1` | - |
| `sentAt_ttl` | `sentAt: 1` | TTL: the outbox retention ([Retentions](#retentions)); an entry without `sentAt` never expires |

The operations:

- **Append**: `insertOne` of the fields above, in the caller's transaction (or on its own).
- **Claim** (`owner`, lease, `limit`): a *pending* entry has `{sentAt: null, failedAt: null}`; it is *claimable by
  owner* when `{$or: [{owner: null}, {owner: <owner>}, {leaseUntil: {$lte: <now>}}]}`. The relay finds the pending,
  claimable entries not yet won in this claim (`_id: {$nin: [...]}`), sorted `{createdAt: 1, seq: 1}`, limited to what is
  still wanted; then takes each with its own `findOneAndUpdate` whose filter is `_id` plus both conditions again (with a
  fresh `now`), and `{$set: {owner: <owner>, leaseUntil: <now + lease>}}`. An update that matches nothing was won by
  another relay: of two relays racing for an entry, exactly one wins it. It repeats until `limit` entries are won or no
  candidate is left, and returns them sorted by `(createdAt, seq)`. No transaction.
- **Mark sent**: `updateMany({_id: {$in: ids}}, {$set: {sentAt: <now>}})`. `owner` and `leaseUntil` stay.
- **Mark an attempt failed**: `{$inc: {attempts: 1}}`; the entry stays its holder's until the lease passes.
- **Mark failed**: `{$inc: {attempts: 1}, $set: {failedAt: <now>}}`; never claimed again, never expired by the TTL.
  The error text is not stored.
- **Pending count** and **oldest pending**: `countDocuments` and the first document, sorted `{createdAt: 1, seq: 1}`,
  of `{sentAt: null, failedAt: null}`.
- **Purge**: `deleteMany({sentAt: {$lt: <bound>}})`, besides the TTL index.

## processed_events

The idempotency markers: one document per handled event and stage.

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | The marker id: `processor:<name>:<eventId>`, `saga:<sagaType>:<eventId>`, `ingress:<source>:<key>`, `failed:<sagaId>:<seq>` ([identifiers](/docs/library-authors/message-store-add-ons/#the-stores)). |
| `type` | `string` | always | The event's type name. |
| `processedAt` | `date` | always | When it was handled; the retention counts from it. |
| `processor` | `string` | optional | The processor's name. |
| `topic` | `string` | optional | The source the event was delivered from. |
| `partition` | `int` or `string` | optional | Its segment ([Segments and positions](#segments-and-positions)). |
| `offset` | `long` or `string` | optional | Its position. |

`processor`, `topic`, `partition` and `offset` are written together, only on a [stage-1 marker](/docs/library-authors/message-store-add-ons/#stage-1-marker)
of a delivered event; every other marker has only the first three fields and is never deleted by a reset.

| Index | Keys | Options |
|---|---|---|
| `processedAt_ttl` | `processedAt: 1` | TTL: the idempotency retention |

- **Record**: `insertOne` in the handler's transaction (a saga marker: in the saga's). A duplicate key error (code
  11000) means the event was handled already: the caller aborts the transaction, which the error may have spoiled.
- **Exists**: a `find` by `_id`.
- **Delete a processor's markers in replay ranges**: per range, `deleteMany({processor, topic: <source>, partition:
  <segment>, offset: {$gte: <from>, $lt: <until>}})`, each value encoded as stored. No transaction.
- **Purge**: `deleteMany({processedAt: {$lt: <bound>}})`, besides the TTL index.

## dead_letters

One document per parked record, in dead-letter mode `collection`. A `SEQUENCED` letter, in the shape of the fixtures
both libraries' contract tests share:

```json
{
  "_id": "orders:orders.events:1:43",
  "processor": "orders",
  "topic": "orders.events",
  "partition": 1,
  "offset": {"$numberLong": "43"},
  "key": "order-7",
  "eventId": "evt-8",
  "eventType": "orders.OrderShipped",
  "headers": {"type": "orders.OrderShipped", "id": "evt-8"},
  "payload": "{\"orderId\":\"order-7\"}",
  "reason": "SEQUENCED",
  "error": {"type": "Sequenced", "message": "an earlier letter for this key is parked: orders:orders.events:1:42"},
  "blockedBy": "orders:orders.events:1:42",
  "attempts": 0,
  "parkedAt": {"$date": "2026-11-04T10:00:06.250Z"},
  "lastAttemptAt": {"$date": "2026-11-04T10:00:06.250Z"},
  "expireAt": {"$date": "2026-12-04T10:00:06.250Z"}
}
```

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | `<processor>:<source>:<segment>:<position>`, the segment and position as text: parking the same record twice finds the first letter. |
| `processor` | `string` | always | The processor that parked it. |
| `topic` | `string` | always | The record's source. |
| `partition` | `int` or `string` | always | Its segment. |
| `offset` | `long` or `string` | always | Its position. |
| `key` | `string` | optional | The record's key. Absent: no key (the letter blocks nothing). |
| `eventId` | `string` | optional | The `id` header; absent when the header is missing or blank. |
| `eventType` | `string` | optional | The `type` header; absent when the header is missing or blank. |
| `headers` | `object` of `string` | always | The record's headers as text (a blank `id` or `type` header is kept here). |
| `payload` | `string` | optional | The record's value when it is valid UTF-8 and not empty. |
| `payloadBinary` | `binData` (subtype 0) | optional | The value when it is not valid UTF-8. Neither field: an empty value. |
| `reason` | `string` | always | `HANDLER_FAILED`, `SEQUENCED` or `INVALID`. |
| `error` | `object` | always | `{type: string, message: string}`: the error's type (an exception's simple class name, `"Sequenced"` or `"InvalidMessage"`) and its message, cut at 2000 characters (code points). |
| `blockedBy` | `string` | optional | A `SEQUENCED` letter's head: the `_id` of the letter it waits behind. |
| `attempts` | `int` | always | Handler attempts made (`0` for `SEQUENCED` and `INVALID`). |
| `parkedAt` | `date` | always | When it was parked. |
| `lastAttemptAt` | `date` | always | The last attempt; `parkedAt` when parked. |
| `expireAt` | `date` | always | `parkedAt` plus the dead-letter retention: the TTL index removes it then. |
| `replay` | `bool` | optional | `true` when parked while its processor replayed the record; written only when true, absent is false. |

| Index | Keys | Options |
|---|---|---|
| `dead_letters_processor_key_offset` | `processor: 1, key: 1, offset: 1` | - |
| `dead_letters_processor_parked` | `processor: 1, parkedAt: 1` | - |
| `dead_letters_expire` | `expireAt: 1` | TTL, `expireAfterSeconds: 0` (each letter carries its own expiry) |

Every write commits on its own, outside the caller's transaction, except a retry's delete.

- **Park**: `insertOne`; a duplicate key error means "already parked", and the first letter stays as it is.
- **Head of a key**: the first `_id` of `{processor, key, reason: {$ne: "INVALID"}}` sorted `{offset: 1, _id: 1}`.
  **An earlier letter**: the same with `offset: {$lt: <position>}`.
- **Parked keys** of a processor's segments: the `key` of the letters matching `{processor, topic: <source>,
  partition: {$in: [...]}, reason: {$ne: "INVALID"}, key: {$exists: true}}`.
- **List**: sorted `{parkedAt: 1, _id: 1}`; **summaries**: `_id`, `key`, `offset`, `reason`, `parkedAt` of a processor's
  letters, sorted `{offset: 1, _id: 1}`.
- **Record a failed retry**: `updateOne({_id}, {$inc: {attempts: 1}, $set: {reason: "HANDLER_FAILED", error: {type,
  message}, lastAttemptAt: <now>}, $unset: {blockedBy: ""}})`.
- **Delete**: `deleteOne({_id})` on its own, or in the retry's transaction, so the letter goes only if the retry commits.

## processor_control

One document per event processor. Unlike the other collections, **every field is always written**, `null` or `[]`
when it has no value; a reader takes a missing field for `null`, `false` or `[]`, and a missing document for a
processor that is not paused, not locked and not replaying.

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | The processor's name. |
| `paused` | `bool` | always | Whether it is paused. |
| `pausedAt` | `date` or `null` | always | When it was paused; `null` when not paused. |
| `pausedBy` | `string` or `null` | always | Who paused it, as the library names the requester; `null` when not paused. |
| `operation` | `object` or `null` | always | The reset holding the lock: `{id: string, kind: string, leaseUntil: date, preparedAt: date}`, written in that order; `kind` is `reset`. `null`: unlocked. |
| `replay` | `array` | always | The replay ranges left, in order: `{topic, partition, from, until}`, the source, the segment and the two positions ([Segments and positions](#segments-and-positions)), written in that order. |
| `updatedAt` | `date` | always | The last write. |

No index besides `_id`. Every write commits on its own, outside any transaction.

- **Pause or resume**: an upsert on `{_id}` with `$set` of `paused`, `pausedAt`, `pausedBy` (`null` on a resume) and
  `updatedAt`, and `$setOnInsert` of the other fields' empty values (`operation: null`, `replay: []`).
- **Take the lock** (operation `op`, lease until `t`): first a renewal (below); when it matches nothing, an upsert with
  the filter `{_id, $or: [{operation: null}, {"operation.leaseUntil": {$lte: <now>}}]}`, `$set` of `operation:
  {id: op, kind: "reset", leaseUntil: t, preparedAt: <now>}` and `updatedAt`, and `$setOnInsert` of `paused: false`,
  `pausedAt: null`, `pausedBy: null`, `replay: []`. When another operation holds the lock the filter does not match an
  existing document, the upsert tries to insert its `_id` and fails with a duplicate key: the lock is held, and its
  holder is read from the document.
- **Renew**: `updateOne({_id, "operation.id": op}, {$set: {"operation.leaseUntil": t, updatedAt: <now>}})`;
  `preparedAt` stays.
- **Release**: `updateOne({_id, "operation.id": op}, {$set: {operation: null, updatedAt: <now>}})`. **Expire**: the
  same with `"operation.leaseUntil": {$lte: <now>}` added to the filter.
- **Set the replay ranges**: `$set` of `replay` and `updatedAt` on `{_id}` (on a missing document: see the differences).
- **Remove a range**: `updateOne({_id, replay: {$elemMatch: <range>}}, {$pull: {replay: <range>}, $set: {updatedAt:
  <now>}})`, the range encoded as stored; removed when the update modified the document.

## external_calls

One record per idempotency key of an idempotent external call.

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | The call's idempotency key. |
| `status` | `string` | always | `IN_PROGRESS`, `SUCCEEDED`, `FAILED` or `UNKNOWN`. |
| `reply` | `string` | optional | A `SUCCEEDED` call's reply as JSON text (any JSON value). |
| `error` | `string` | optional | A `FAILED` call's error as JSON text, `{"code","message"}`. |
| `attempts` | `int` | always | Calls made under this key. |
| `updatedAt` | `date` | always | The last write; the retention counts from it. |
| `leaseUntil` | `date` | optional | While `IN_PROGRESS`: until when `owner` holds the call. Absent once settled. |
| `owner` | `string` | optional | While `IN_PROGRESS`: the random token of the call that holds it. Absent once settled. |

| Index | Keys | Options |
|---|---|---|
| `updatedAt_ttl` | `updatedAt: 1` | TTL: the external-calls retention |

Every write is a single-document write that commits on its own, apart from the caller's transaction, and every write
after the insert is conditional:

- **Insert**: `insertOne` (an `IN_PROGRESS` record with its `owner` and `leaseUntil`); a duplicate key error means an
  earlier call of the key exists.
- The *owned* writes match `{_id, status: "IN_PROGRESS", owner: <token>}`: **succeed** sets `status: "SUCCEEDED"`,
  `reply`, `updatedAt` and unsets `leaseUntil`, `owner` and `error`; **fail** sets `status: "FAILED"`, `error`,
  `updatedAt` and unsets `leaseUntil` and `owner`; **mark unknown** sets `status: "UNKNOWN"`, `updatedAt` and unsets
  `leaseUntil` and `owner`; **reset** deletes the record.
- The writes on a record read earlier match `{_id, status: "IN_PROGRESS", owner: <as read>, leaseUntil: <as read>}`
  (`null` for a field read as absent): **take over** is a `findOneAndUpdate` that sets the new `owner`, `leaseUntil`
  and `updatedAt` and increments `attempts`, returning the document after; **give up** settles it as `UNKNOWN` like
  mark unknown.
- Each reports whether it matched: a write that matched nothing changed nothing.

## sagas

One document per saga instance.

```json
{
  "_id": "7f6c1f0e-5a53-4f3e-9a0a-1d2f6f0c9b11",
  "type": "orders.PaymentSaga",
  "state": "{\"orderId\":\"order-1\",\"amount\":12.30}",
  "associations": [{"k": "orderId", "v": "order-1"}],
  "startKey": "orders.PaymentSaga|orderId=order-1",
  "ended": false,
  "version": {"$numberLong": "3"},
  "createdAt": {"$date": "2026-11-03T10:00:00Z"},
  "updatedAt": {"$date": "2026-11-03T10:05:00.250Z"}
}
```

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | The instance id, a random UUID. |
| `type` | `string` | always | The saga's type name. |
| `state` | `string` | always | The saga object as JSON text. |
| `associations` | `array` | always | `{k: string, v: string}` pairs that route events to the instance; may be empty. |
| `startKey` | `string` | optional | `<type>|<key>=<value>`, with `%`, `|` and `=` percent-escaped in each part as `%25`, `%7C` and `%3D`, in that order: unique among live instances. Absent for an instance started with `forceNew`. |
| `ended` | `bool` | always | `false` while the instance is live. |
| `endedAt` | `date` | optional | When it ended; absent while live. |
| `version` | `long` | always | The optimistic version: `0` when created, one more per write. |
| `createdAt` | `date` | always | When it was created. |
| `updatedAt` | `date` | always | The last write. |

| Index | Keys | Options |
|---|---|---|
| `type_associations_live` | `type: 1, "associations.k": 1, "associations.v": 1` | partial: `{ended: false}` |
| `startKey_live_unique` | `startKey: 1` | unique; partial: `{ended: false, startKey: {$exists: true}}` |
| `endedAt_ttl` | `endedAt: 1` | TTL: the ended-sagas retention |

Ended instances neither route events nor hold their start key: both partial filters leave them out. That is why an
absent `startKey` must be absent, not `null`: `{$exists: true}` matches a `null`, and two live `forceNew` instances
would then collide.

Every operation runs in the saga's transaction:

- **Find by id**; **find live**: `{type, ended: false, associations: {$elemMatch: {k, v}}}`.
- **Insert**: `insertOne`. A duplicate key error on `startKey_live_unique`: another live instance holds the start
  key.
- **Update**: `replaceOne({_id, version: <expected>}, <the whole document, version + 1>)`: optimistic concurrency.
  Matched nothing: another writer changed the instance, and the runtime retries the event.
- **Count the live instances per type**: `[{$match: {ended: false}}, {$group: {_id: "$type", n: {$sum: 1}}}]`, outside
  any transaction.

A write conflict (code 112) or any error carrying MongoDB's TransientTransactionError label is the store's retryable
conflict, and the runtime retries the whole attempt. Rust maps it so on every write and at commit. Kotlin maps it on
the writes of the saga stores and at commit, but not on an outbox append or a marker write, which raise the driver's
exception as it is, and not at commit when the application declares a transaction manager of its own instead of the
add-on's.

## saga_dispatch

The saga-side outbox: one document per command or event a saga recorded in its transaction.

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | `<sagaId>:<seq>`; a command's `idempotency-key` too. |
| `sagaId` | `string` | always | The saga instance. |
| `seq` | `long` | always | The order within the saga: `version * 1000 + index`. |
| `kind` | `string` | always | `COMMAND` or `EVENT`. |
| `type` | `string` | always | The message's type name. |
| `payload` | `string` | always | The message's JSON text. |
| `headers` | `object` of `string` | always | Today `correlation-id`: the correlation id of the message that caused the entry. |
| `routingKey` | `string` | optional | A command's routing key or an event's key. |
| `createdAt` | `date` | always | When it was recorded. |
| `dispatchedAt` | `date` | optional | When it was sent. |
| `attempts` | `int` | always | Send attempts so far; `0` when recorded. |
| `nextAttemptAt` | `date` | optional | Not retried before this time. |
| `failedAt` | `date` | optional | When it was given up on. |
| `failureReason` | `string` | optional | With `failedAt`: `NO_HANDLER`, `DENIED`, `INVALID`, `FAILED`, `UNKNOWN_OUTCOME` or `EXHAUSTED`. |
| `failureMessage` | `string` | optional | With `failedAt`: what the failure notice says. |
| `noticePending` | `bool` | optional | `true` until the failure notice of a failed command was delivered locally. |
| `noticeAttempts` | `int` | optional | Failed deliveries of the notice. |
| `noticeNextAt` | `date` | optional | The notice is not delivered before this time; also reserves it for the instance that claimed it. |

An entry is *pending* while `{dispatchedAt: null, failedAt: null}`.

| Index | Keys | Options |
|---|---|---|
| `sagaId_1_seq_1` | `sagaId: 1, seq: 1` | - |
| `dispatchedAt_1_failedAt_1_sagaId_1_seq_1` | `dispatchedAt: 1, failedAt: 1, sagaId: 1, seq: 1` | - |
| `dispatchedAt_ttl` | `dispatchedAt: 1` | TTL: the saga-dispatch retention |
| `failedAt_ttl` | `failedAt: 1` | TTL: the failed retention |
| `noticePending_noticeNextAt` | `noticeNextAt: 1` | partial: `{noticePending: true}` |

- **Record**: `insertMany` in the saga's transaction. An `EVENT` entry whose payload the outbox would refuse is refused
  first, so nothing of the attempt commits.
- **Due sagas** (`now`, the sagas to skip, `limit`), outside any transaction, with `allowDiskUse`:

    ```json
    [
      {"$match": {"dispatchedAt": null, "failedAt": null, "sagaId": {"$nin": ["<skipped>"]}}},
      {"$sort": {"sagaId": 1, "seq": 1}},
      {"$group": {"_id": "$sagaId", "next": {"$first": "$nextAttemptAt"}, "since": {"$first": "$createdAt"}}},
      {"$match": {"$or": [{"next": null}, {"next": {"$lte": "<now>"}}]}},
      {"$sort": {"since": 1, "_id": 1}},
      {"$limit": "<limit>"}
    ]
    ```

    A saga is due when its first pending entry is; the oldest such entry first.
- **Next pending** of a saga: the first of `{sagaId, dispatchedAt: null, failedAt: null}` sorted `{seq: 1}`.
- **Mark dispatched**: `$set: {dispatchedAt}`, in the relay's transaction (for an event, the one that appends it to the
  outbox).
- **Schedule a retry**: `$set: {attempts, nextAttemptAt}`.
- **Mark a command failed**: `$set: {failedAt, failureReason, failureMessage, attempts, noticePending: true,
  noticeAttempts: 0, noticeNextAt}`, one update.
- **Claim a due notice**: `findOneAndUpdate({noticePending: true, $or: [{noticeNextAt: null}, {noticeNextAt: {$lte:
  <now>}}]}, {$set: {noticeNextAt: <now + lease>}})`, sorted `{noticeNextAt: 1}`, returning the document after; repeated
  for a batch.
- **Retry a notice**: `$set: {noticeAttempts, noticeNextAt}`. **Clear it**: `$unset` of `noticePending`,
  `noticeAttempts` and `noticeNextAt`.
- **Pending count**: `countDocuments({dispatchedAt: null, failedAt: null})`.

## saga_dispatch_leases

The lease that lets one relay at a time work through a saga's dispatch entries.

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | The saga id. |
| `owner` | `string` | always | The relay holding it (a random id per relay instance). |
| `until` | `date` | always | Until when it holds it. |

| Index | Keys | Options |
|---|---|---|
| `until_ttl` | `until: 1` | TTL, `expireAfterSeconds: 0` |

An expired lease is as good as none; the TTL index only tidies up. No operation joins a transaction.

- **Claim**: an upsert with the filter `{_id: <sagaId>, until: {$lt: <now>}}` and `{$set: {owner, until}}`. While a
  lease holds, the filter does not match the existing document and the insert fails with a duplicate key: the claim
  fails. A lapsed lease is updated in place, a missing one inserted.
- **Renew**: `updateOne({_id, owner}, {$set: {until}})`; renewed when it matched.
- **Release**: `deleteOne({_id, owner})`.

## deadlines

One document per deadline a saga scheduled.

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | The deadline id, a random UUID. |
| `sagaType` | `string` | always | The saga's type name. |
| `sagaId` | `string` | always | The saga instance. |
| `name` | `string` | always | The deadline's name. |
| `payload` | `string` | optional | The payload as JSON text (any JSON value); absent when there is none. |
| `payloadType` | `string` | optional | The payload's type name, as the scheduling library names it; absent when there is no payload. |
| `dueAt` | `date` | always | When it is due. |
| `status` | `string` | always | `SCHEDULED`, `FIRED` or `CANCELLED`. |
| `claimedBy` | `string` | optional | The scheduler instance that claimed it (a random id per instance). |
| `claimedUntil` | `date` | optional | Until when the claim holds; a lapsed claim lets it fire again. |
| `finishedAt` | `date` | optional | When it was fired or cancelled. |
| `correlationId` | `string` | optional | The correlation id of the message that scheduled it. An empty one is written as no field, and an absent one reads as none. |

| Index | Keys | Options |
|---|---|---|
| `status_1_dueAt_1` | `status: 1, dueAt: 1` | - |
| `sagaId_1_status_1` | `sagaId: 1, status: 1` | - |
| `finishedAt_ttl` | `finishedAt: 1` | TTL: the deadlines retention |

- **Insert**, **find a scheduled one** (`{_id, status: "SCHEDULED"}`), **cancel** (by id and saga, by saga and name,
  or every one of a saga: `updateMany` of the filter plus `status: "SCHEDULED"`, `$set: {status: "CANCELLED",
  finishedAt}`) and **mark fired** (`updateOne({_id, status: "SCHEDULED"}, {$set: {status: "FIRED", finishedAt}})`,
  fired when it modified the document) run in the saga's transaction.
- **Claim a due deadline**, outside any transaction: `findOneAndUpdate({status: "SCHEDULED", dueAt: {$lte: <now>},
  $or: [{claimedUntil: null}, {claimedUntil: {$lt: <now>}}]}, {$set: {claimedBy, claimedUntil}})`, sorted `{dueAt: 1}`,
  returning the document after. The earliest due deadline goes to exactly one scheduler until its claim lapses.
- **Count the overdue ones per name**: `[{$match: {status: "SCHEDULED", dueAt: {$lte: <now>}}}, {$group: {_id:
  "$name", n: {$sum: 1}}}]`.

## saga_failures

One document per saga event that failed all its attempts, parked for a re-delivery or a discard.

| Field | Type | Present | Meaning |
|---|---|---|---|
| `_id` | `string` | always | `<sagaType>:<eventId>`. |
| `sagaType` | `string` | always | The saga's type name. |
| `eventId` | `string` | always | The event's id. |
| `eventType` | `string` | always | The event's type name. |
| `payload` | `string` | always | The event's JSON text. |
| `headers` | `object` of `string` | always | The message headers, with `correlationId` and `userId` when known. |
| `error` | `string` | always | The last error, as text. |
| `attempts` | `int` | always | Attempts made. |
| `firstFailedAt` | `date` | always | The first failure. |
| `lastFailedAt` | `date` | always | The last failure; the retention counts from it. |

| Index | Keys | Options |
|---|---|---|
| `sagaType_1_lastFailedAt_1` | `sagaType: 1, lastFailedAt: 1` | - |
| `lastFailedAt_ttl` | `lastFailedAt: 1` | TTL: the failed retention |

All in the saga's transaction: **find** by `_id`; **save** is `replaceOne({_id}, <document>)` with `upsert`; **failed
again** is `updateOne({_id}, {$inc: {attempts: <n>}, $set: {error, lastFailedAt}})`; **delete**; **list**, optionally
`{sagaType}`, sorted `{lastFailedAt: 1}`.

## Transactions

The writes that join the caller's transaction, and so need the replica set: an outbox append (when there is a
transaction), a processed-event marker, a dead letter's delete by a retry, and the saga runtime's work on `sagas`,
`saga_dispatch` (record, mark dispatched), `deadlines` (insert, find, cancel, mark fired), `saga_failures` and its
markers in `processed_events`. Everything else (relay claims and marks, parking, processor control, external calls,
the deadline and notice claims, the saga dispatch leases, purges) is a single-document or single-statement write that
commits on its own; the Kotlin add-on lets more of these join a transaction that happens to be active
([the differences](#where-the-two-add-ons-differ-today)).

Inside a transaction, a write that conflicts with another transaction fails at once with a write conflict instead of
waiting: the store reports it as the retryable conflict, with the Kotlin exceptions given under [sagas](#sagas).

## Retentions

| TTL index | Kotlin property | Rust `snodra_messaging::Config` field | Default |
|---|---|---|---|
| `outbox` `sentAt_ttl` | `snodra.messaging.outbox.retention` | `outbox_retention` | 7 days |
| `processed_events` `processedAt_ttl` | `snodra.messaging.idempotency.retention` | `idempotency_retention` | 30 days |
| `external_calls` `updatedAt_ttl` | `snodra.messaging.external.calls.retention` | `external_calls_retention` (`SNODRA_EXTERNAL_CALLS_RETENTION_MS`) | 30 days |
| `sagas` `endedAt_ttl` | `snodra.messaging.sagas.ended-retention` | `sagas_ended_retention` (`SNODRA_SAGAS_ENDED_RETENTION_MS`) | 30 days |
| `saga_dispatch` `dispatchedAt_ttl` | `snodra.messaging.sagas.dispatch-retention` | `sagas_dispatch_retention` (`SNODRA_SAGAS_DISPATCH_RETENTION_MS`) | 7 days |
| `saga_dispatch` `failedAt_ttl`, `saga_failures` `lastFailedAt_ttl` | `snodra.messaging.sagas.failed-retention` | `sagas_failed_retention` (`SNODRA_SAGAS_FAILED_RETENTION_MS`) | 30 days |
| `deadlines` `finishedAt_ttl` | `snodra.messaging.deadlines.retention` | `deadlines_retention` (`SNODRA_DEADLINES_RETENTION_MS`) | 7 days |

A dead letter's retention is not an index setting: the library computes each letter's `expireAt` from it
(`snodra.messaging.events.dead-letter.retention`, `SNODRA_EVENTS_DEAD_LETTER_RETENTION_MS`, 30 days by default). The
TTL indexes with `expireAfterSeconds: 0` (`dead_letters_expire`, `until_ttl`) have no setting. MongoDB's TTL monitor
deletes about once a minute, so an expired document can still be read until it does.

## Where the two add-ons differ today

What the two official add-ons do not yet do the same, with what each does. None of these stops the two from reading
each other's documents today; each is a choice to settle before a third add-on copies one side.

- **Outbox fields without a value.** On append, Rust writes `key: null` for an event without a key, and `sentAt:
  null` and `failedAt: null`; Kotlin leaves all three out. Every query uses `{field: null}`, which matches both.
- **Integers in the outbox payload.** Rust stores every JSON integer as a `long` (`{"n":1}` holds a `long`);
  Kotlin, whose conversion is the Java driver's JSON reader, stores an integer that fits in 32 bits as an `int` and a
  larger one as a `long`. Both read either back as the same number.
- **The relayed text of a `double`.** Both relay compact relaxed Extended JSON, but a `double` is printed by each
  language's own writer: a payload holding `1.0E+10` is relayed as `1.0E+10` by Kotlin and as `10000000000.0` by
  Rust. The value is the same; the bytes on the event store depend on which relay sent the entry.
- **Replay ranges on a processor without a document.** Rust sets `replay` with an upsert (`$setOnInsert` of
  `paused: false`, `pausedAt: null`, `pausedBy: null`, `operation: null`), so the document is created when missing;
  Kotlin updates an existing document only, and on a missing one the write does nothing.
- **A lock upsert that hits a duplicate key.** Rust tries the renewal once more (the same operation may have taken the
  lock meanwhile) and then reports the holder, or an error when the lock was released in between; Kotlin reports
  the lock as held with whatever operation the document holds then, possibly none.
- **An `EVENT` dispatch entry whose payload cannot be published.** Kotlin marks it failed as a command (`attempts`,
  `failedAt`, `failureReason: "INVALID"`, `failureMessage`, `noticePending: true`, `noticeAttempts: 0`,
  `noticeNextAt`) and then clears the three notice fields in a second update; its relay only clears a pending notice of
  an `EVENT` entry (what a crash between the two writes leaves). Rust writes `failedAt`, `failureReason: "INVALID"` and
  `failureMessage` in one update, leaves `attempts` as it is and writes no notice fields; its relay delivers any pending
  notice that carries a `failureReason`, whatever the entry's `kind`.
- **A deadline's `payloadType`.** Kotlin writes the payload class's message type name when it has one, else its JVM
  class name; Rust writes the Rust type path of the payload type (`std::any::type_name`). Neither add-on interprets the
  field; the values of one language mean nothing to the other.
- **What a reader requires.** Rust fails on a document missing a field it requires where Kotlin falls back to a
  default: the outbox `headers` (Kotlin: empty), a dead letter's `attempts` (Kotlin: `0`), `error` (Kotlin: empty type
  and message), `lastAttemptAt` (Kotlin: `parkedAt`) and `offset` (Kotlin: an empty position, in a letter and in a
  summary), a saga failure's `attempts` (Kotlin: `0`), a `processor_control` `operation` missing `id`, `kind`,
  `leaseUntil` or `preparedAt` (Kotlin: an empty id, `reset`, the epoch) and a replay range missing one of its four
  fields (Kotlin skips that range). Rust also refuses a `double` where it expects an integer, which Kotlin reads as any
  number, and a `headers` value that is not a `string`, which Kotlin turns into its text. Writers that follow the
  tables above never meet these cases.
- **A duplicate key at a write.** Rust reports a duplicate key error (code 11000) of any write it does not expect
  one from (a saga insert on `startKey_live_unique`, a dispatch entry, a marker) as its retryable conflict, like a
  write conflict; Kotlin reports it as Spring's duplicate-key exception, and its core decides what follows.
- **The order of header fields.** Rust writes a dead letter's `headers` sorted by name and the other header maps in no
  fixed order; Kotlin keeps the order it received them in. Nothing reads the order.
- **Which operations can join a transaction.** Rust uses a session only for the writes listed under
  [Transactions](#transactions) and runs everything else outside any session. Kotlin sends far more through the
  session-aware database, so it joins a transaction when one is active on the calling thread: every outbox operation
  (append, claim, mark sent, mark failed, counts, purge), every `processed_events` operation but the deletion of
  replay ranges (record, exists, purge), every `external_calls` operation (its core runs each in a short transaction
  of its own), and every operation on `sagas`, `saga_dispatch` (the relay's writes and the notice claims included),
  `saga_dispatch_leases`, `deadlines` (the claim and the count included) and `saga_failures`. Only `dead_letters`
  (but a retry's delete), `processor_control` and the deletion of markers in replay ranges always commit on their own
  in Kotlin. When nothing is active, the two do the same; each of these is a single-document or single-statement
  write either way.

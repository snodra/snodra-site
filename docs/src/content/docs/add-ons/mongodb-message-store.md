---
title: "MongoDB message store"
---

The message store in the service's own MongoDB database. Use it when MongoDB already holds your
domain state: the outbox write joins the same transaction as your document writes, so the state
change and the event commit together.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-mongo:0.6.1` |
| Rust | `snodra-messaging-mongo = "0.8"` |
| Go | `github.com/snodra/snodra-messaging-go/mongo` (`go get github.com/snodra/snodra-messaging-go/mongo@v0.7.0`) |
| Python | `snodra-messaging-mongo` (`pip install snodra-messaging-mongo==0.8.0`) |

The Kotlin module brings Spring Data MongoDB; a service needs a `MongoTemplate`. The Rust crate takes
a `mongodb::Client` and a database from your code; it reads no connection setting of its own. The Go
module is one add-on module: `mongo.New(mongo.FromEnv())` creates its own client, and
`mongo.NewWithClient` uses the service's, then the store is passed to `snodra.New` with `WithStore`
([Go events](/docs/messaging/go/api/#events)). The Python package is `snodra-messaging-mongo`:
`MongoStore(MongoConfig.from_env())` creates its own client, or takes a service's `AsyncMongoClient`, and
is passed to `snodra.App` with `store=` ([Python events](/docs/messaging/python/api/#events)).

## Configuration

Kotlin:

| Key | Default | Meaning |
|---|---|---|
| `snodra.messaging.store.type` | the only one | `mongo` chooses this store when another message store is on the classpath; naming another makes it step back |
| `snodra.messaging.store.init-schema` | `true` | Create the indexes at startup; `false` checks they are there |
| `spring.mongodb.uri` | required | The database, for example `mongodb://mongo:27017/orders?replicaSet=rs0` (Spring Boot 4 key) |
| `snodra.messaging.outbox.retention` | `7d` | Sent outbox entries are deleted after this |
| `snodra.messaging.idempotency.retention` | `30d` | Processed-event markers are deleted after this |
| `snodra.messaging.events.dead-letter.retention` | `30d` | Dead letters are deleted after this |
| `snodra.messaging.sagas.ended-retention` | `30d` | Ended sagas are deleted after this |

The same retentions exist for external calls, deadlines, saga dispatch and failures. They map to TTL
indexes, so MongoDB's TTL monitor (about every 60 seconds) does the deleting.

Rust: `SNODRA_STORE_INIT_SCHEMA` and the `SNODRA_*_RETENTION_MS` variables. The client, database and
pool are yours; pass the store to `.store(...)`.

Go, through `mongo.FromEnv` and `mongo.Config`:

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_STORE_MONGO_URI` | required | The connection string, `mongodb://...` or `mongodb+srv://...`; the database must be a replica set (a single-node one is enough) |
| `SNODRA_STORE_MONGO_DATABASE` | required | The service's database, which holds the shared collections |
| `Config.OutboxRetention` | 7d | Sent outbox documents are deleted after this (`sentAt` TTL) |
| `Config.ProcessedRetention` | 30d | Processed-event markers are deleted after this (`processedAt` TTL) |
| `Config.ExternalCallRetention` | 30d | External-call records, after their last update |
| `Config.SagaEndedRetention` | 30d | Ended sagas |
| `Config.SagaDispatchRetention` | 7d | Dispatched saga entries |
| `Config.DeadlineRetention` | 7d | Fired or cancelled deadlines |
| `Config.FailedRetention` | 30d | What failed for good |

`mongo.FromEnv` reads the URI and the database and leaves the retentions at their defaults; set them
on the returned `Config`. `Store.InitSchema` creates every index and TTL index idempotently;
`SNODRA_STORE_INIT_SCHEMA=false` makes `App.Start` check them instead. Give every instance sharing a
database the same retentions. The full Go settings are in
[Go configuration](/docs/messaging/go/configuration/#mongodb-mongofromenv).

Python, through `MongoConfig.from_env` and `MongoConfig`:

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_STORE_MONGO_URI` | required | The connection string, `mongodb://...` or `mongodb+srv://...`; the database must be a replica set (a single-node one is enough) |
| `SNODRA_STORE_MONGO_DATABASE` | required | The service's database, which holds the shared collections |
| `MongoConfig.outbox_retention` | 7d | Sent outbox documents are deleted after this (`sentAt` TTL) |
| `MongoConfig.processed_retention` | 30d | Processed-event markers are deleted after this (`processedAt` TTL) |
| `MongoConfig.external_call_retention` | 30d | External-call records, after their last update |
| `MongoConfig.saga_ended_retention` | 30d | Ended sagas |
| `MongoConfig.saga_dispatch_retention` | 7d | Dispatched saga entries |
| `MongoConfig.deadline_retention` | 7d | Fired or cancelled deadlines |
| `MongoConfig.failed_retention` | 30d | What failed for good |

`MongoConfig.from_env()` reads the URI and the database and leaves the retentions at their defaults; set them
on the returned `MongoConfig`. `StoreLifecycle.init_schema()` creates every index and TTL index idempotently;
`SNODRA_STORE_INIT_SCHEMA=false` makes `App.start()` check them instead. Give every instance sharing a
database the same retentions. The package is `snodra-messaging-mongo`; the full Python settings are in
[Python configuration](/docs/messaging/python/configuration/#mongodb-mongoconfigfrom_env).

## Guarantees

- **Transactions, not a side write.** The store joins the service's transaction through a MongoDB
  session. The database must be a **replica set**; a single-node replica set is enough.
- **The outbox is atomic with your state.** A rollback leaves no event and no marker.
- **The outbox is the `outbox` collection.** One document per appended event: `_id` is the event id
  (a string), with `type`, `key` (`null` when the event has none), `headers`, `payload` (the event's
  JSON object as a BSON document), `createdAt`, `seq`, `sentAt` (`null` until sent), `attempts` and
  `failedAt`; `owner` and `leaseUntil` are there while a relay holds the entry. The
  `sentAt_1_createdAt_1_seq_1` index orders claims and `sentAt_ttl` removes sent entries after the
  outbox retention.
- **Markers are in `processed_events`.** `_id` is `processor:<processor>:<eventId>` (the stage-1
  marker of a handler), with `type`, `processedAt`, `processor`, `source`, `segment` and `position`;
  `processedAt_ttl` removes them after the idempotency retention.
- **Shared data layout.** The collections and document fields are the ones the Kotlin library has
  always written — `outbox`, `processed_events`, `dead_letters`, `processor_control`,
  `external_calls`, `sagas`, `saga_dispatch`, `saga_dispatch_leases`, `deadlines`, `saga_failures`.
  A Kotlin, Rust, Go or Python instance can share one database, and existing data needs no migration. Every
  field and index: [MongoDB layout](/docs/library-authors/mongodb-layout/).
- **No `_class` fields.** Documents are explicit, so a schema change in one library does not break
  the other.
- **One database per logical service.** Instances share it; two different services keep separate
  databases, because markers and claims carry no service name.
- **All ports through level 4.** The Go (0.7.0) and Python (0.8.0) releases implement the outbox, the processed-event
  markers, the dead letters, the processor control, the external-call records and the saga records; their claims,
  marks and retentions follow the shared layout, and times they stamp themselves come from the application's clock.
  They pass the eleven level-4 store checks, and the saga runtime and the idempotent external-call adapter are part of
  both libraries.

## Capabilities

| Port | Kotlin | Rust | Go | Python |
|---|---|---|---|---|
| Outbox | yes | yes | yes | yes |
| Processed events | yes | yes | yes | yes |
| Dead letters | yes | yes | yes (0.6.0) | yes (0.7.0) |
| Processor control | yes | yes | yes (0.6.0) | yes (0.7.0) |
| External calls | yes | yes | yes (0.7.0) | yes (0.8.0) |
| Sagas | yes | yes | yes (0.7.0) | yes (0.8.0) |

## Read next

- Collections, fields and indexes: [the messaging model](/docs/messaging/).
- Kotlin settings: [Kotlin configuration](/docs/messaging/kotlin/configuration/).
- The Go settings and API: [Go configuration](/docs/messaging/go/configuration/#mongodb-mongofromenv) and
  [Go events](/docs/messaging/go/api/#events).
- The Python settings and API: [Python configuration](/docs/messaging/python/configuration/#mongodb-mongoconfigfrom_env) and
  [Python events](/docs/messaging/python/api/#events).
- The other message store: [SQL](/docs/add-ons/sql-message-store/).
- Why the transaction matters: [Consistency](/docs/concepts/consistency/).

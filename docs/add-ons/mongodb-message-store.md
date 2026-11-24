# MongoDB message store

The message store in the service's own MongoDB database. Use it when MongoDB already holds your
domain state: the outbox write joins the same transaction as your document writes, so the state
change and the event commit together.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-mongo:0.6.1` |
| Rust | `snodra-messaging-mongo = "0.7"` |

The Kotlin module brings Spring Data MongoDB; a service needs a `MongoTemplate`. The Rust crate takes
a `mongodb::Client` and a database from your code; it reads no connection setting of its own.

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

## Guarantees

- **Transactions, not a side write.** The store joins the service's transaction through a MongoDB
  session. The database must be a **replica set**; a single-node replica set is enough.
- **The outbox is atomic with your state.** A rollback leaves no event and no marker.
- **Shared data layout.** The collections and document fields are the ones the Kotlin library has
  always written — `outbox`, `processed_events`, `dead_letters`, `processor_control`,
  `external_calls`, `sagas`, `saga_dispatch`, `saga_dispatch_leases`, `deadlines`, `saga_failures`.
  A Kotlin and a Rust instance can share one database, and existing data needs no migration. Every
  field and index: [MongoDB layout](../library-authors/mongodb-layout.md).
- **No `_class` fields.** Documents are explicit, so a schema change in one library does not break
  the other.
- **One database per logical service.** Instances share it; two different services keep separate
  databases, because markers and claims carry no service name.

## Read next

- Collections, fields and indexes: [the messaging model](../messaging/index.md).
- Kotlin settings: [Kotlin configuration](../messaging/kotlin/configuration.md).
- The other message store: [SQL](sql-message-store.md).
- Why the transaction matters: [Consistency](../concepts/consistency.md).

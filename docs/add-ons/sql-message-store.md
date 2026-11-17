# SQL message store

The message store in the service's own relational database: **PostgreSQL 13 or later**, or **MySQL
8.0.17 or later** (InnoDB, a STRICT `sql_mode`). MariaDB is not supported. Use it when the service
already owns a relational database and wants the outbox in the same transaction as its rows.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-jdbc:0.5.0` |
| Rust | `snodra-messaging-sqlx = "0.6"`, with feature `postgres` or `mysql` |

The Kotlin module runs on the application's `DataSource` through Spring's `JdbcClient`; it needs at
least two connections in the pool. The Rust crate runs on `sqlx` and takes your pool.

## Configuration

Kotlin:

| Key | Default | Meaning |
|---|---|---|
| `snodra.messaging.store.type` | the only one | `jdbc` chooses this store when another message store is on the classpath |
| `snodra.messaging.store.init-schema` | `true` | Apply the schema at startup; `false` checks version 1 or later is present |
| `snodra.messaging.store.jdbc.dialect` | detected | `postgresql` or `mysql`; override only for a compatible database |
| `snodra.messaging.store.jdbc.notify` | `true` | PostgreSQL: appends wake the relay with `LISTEN`/`NOTIFY`; turn it off behind PgBouncer in transaction mode |
| `snodra.messaging.store.jdbc.purge-interval` | `1m` | How often retention runs; `0` turns the purge off |
| `spring.datasource.*` | required | The service's normal Spring Boot connection settings |

Rust: `SNODRA_STORE_SQL_NOTIFY`, `SNODRA_STORE_SQL_PURGE_INTERVAL_MS` and
`SNODRA_STORE_INIT_SCHEMA`; retention variables mirror the Kotlin keys.

## Guarantees

- **Joins the service's transaction.** `DataSourceTransactionManager` and `JpaTransactionManager`
  both bind the connection, so a business write, the outbox entry and the marker commit together.
- **One schema per logical service.** The tables are `snodra_outbox`, `snodra_processed_events`,
  `snodra_dead_letters`, `snodra_processor_control`, `snodra_external_calls`, `snodra_sagas`,
  `snodra_saga_associations`, `snodra_saga_dispatch`, `snodra_deadlines` and `snodra_saga_failures`
  (plus `snodra_schema`). Every column and stored value is shared with the Rust crate, so both
  libraries can share one database.
- **Safe competing relays.** Claims use `SELECT ... FOR UPDATE SKIP LOCKED`; a crashed claimer's rows
  are claimed again after its lease.
- **PostgreSQL wake-up.** `pg_notify('snodra_outbox', '')` runs inside the append's transaction, so a
  rollback sends nothing and a commit wakes the relay at once.
- **No silent truncation.** A missing STRICT mode, an old server, MariaDB or a one-connection pool
  fails the startup with a message naming what is supported.

The schema files are versioned (`V1__snodra.sql`) and the schema is applied once at startup unless
the service runs its own migration.

## Read next

- The full SQL add-on reference: [the messaging model](../messaging/index.md).
- Kotlin settings: [Kotlin configuration](../messaging/kotlin/configuration.md).
- The other message store: [MongoDB](mongodb-message-store.md).
- The transaction guarantee: [Consistency](../concepts/consistency.md).

---
title: "SQL message store"
---

The message store in the service's own relational database: **PostgreSQL 13 or later**, or **MySQL
8.0.17 or later** (InnoDB, a STRICT `sql_mode`). MariaDB is not supported. Use it when the service
already owns a relational database and wants the outbox in the same transaction as its rows.

## Artifact

| Library | Coordinate |
|---|---|
| Kotlin | `com.damoreira.snodra:snodra-messaging-jdbc:0.6.1` |
| Rust | `snodra-messaging-sqlx = "0.8"`, with feature `postgres` or `mysql` |
| Go | `github.com/snodra/snodra-messaging-go/sql` (`go get github.com/snodra/snodra-messaging-go/sql@v0.6.0`) |
| Python | `snodra-messaging-sql` (`pip install snodra-messaging-sql==0.7.0`) |

The Kotlin module runs on the application's `DataSource` through Spring's `JdbcClient`; it needs at
least two connections in the pool. The Rust crate runs on `sqlx` and takes your pool. The Go module
is one add-on module: `sql.New(sql.FromEnv())` owns its `*sql.DB` (ten connections by default, at
least two), and the store is passed to `snodra.New` with `WithStore`
([Go events](/docs/messaging/go/api/#events)). The Python package is `snodra-messaging-sql`:
`SqlStore(SqlConfig.from_env())` owns its connection pool on `asyncpg` (PostgreSQL) or `asyncmy`
(MySQL), and the store is passed to `snodra.App` with `store=`
([Python events](/docs/messaging/python/api/#events)).

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

Go, through `sql.FromEnv` and `sql.Config`:

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_STORE_SQL_URL` | required | `postgres://...`, `postgresql://...`, `mysql://...`, or a native `go-sql-driver/mysql` DSN |
| `SNODRA_STORE_SQL_DRIVER` | detected from the URL | `postgres` or `mysql`; set it only for a URL whose scheme does not say (a native MySQL DSN is detected) |
| `SNODRA_STORE_SQL_NOTIFY` | `true` | PostgreSQL: `pg_notify('snodra_outbox', '')` in the append's transaction wakes the relay; turn it off behind PgBouncer in transaction mode. MySQL always polls |
| `SNODRA_STORE_SQL_PURGE_INTERVAL_MS` | 60000 | How often retention runs; `0` turns the purge off |
| `Config.MaxOpenConns` / `Config.MaxIdleConns` | 10 / 5 | The pool; at least two connections, because a write that commits on its own inside the service's transaction takes a second one |
| `Config.ConnMaxLifetime` | 30m | How long a pooled connection is reused |
| `Config.OutboxRetention` | 7d | Sent outbox rows |
| `Config.ProcessedRetention` | 30d | Processed-event markers |
| `Config.ExternalCallRetention`, `Config.SagaEndedRetention`, `Config.FailedRetention` | 30d | External calls after their last update, ended sagas, what failed for good |
| `Config.SagaDispatchRetention`, `Config.DeadlineRetention` | 7d | Dispatched saga entries, fired or cancelled deadlines |

`sql.FromEnv` reads the URL, the driver, notify and the purge interval and leaves the rest at their
defaults. `SNODRA_STORE_INIT_SCHEMA` (the core variable) decides whether `App.Start` applies V1 or
checks the schema. The full Go settings are in
[Go configuration](/docs/messaging/go/configuration/#sql-sqlfromenv).

Python, through `SqlConfig.from_env` and `SqlConfig`:

| Setting | Default | Meaning |
|---|---|---|
| `SNODRA_STORE_SQL_URL` | required | `postgres://...`, `postgresql://...`, or `mysql://...` |
| `SNODRA_STORE_SQL_DRIVER` | detected from the URL | `postgres` or `mysql`; set it only for a URL whose scheme does not say |
| `SNODRA_STORE_SQL_NOTIFY` | `true` | PostgreSQL: `pg_notify('snodra_outbox', '')` in the append's transaction wakes the relay; turn it off behind PgBouncer in transaction mode. MySQL always polls |
| `SNODRA_STORE_SQL_PURGE_INTERVAL_MS` | 60000 | How often retention runs; `0` or negative turns the purge off |
| `SqlConfig.min_size` / `SqlConfig.max_size` | 1 / 10 | The connection pool (at least two connections, because a write that commits on its own inside the service's transaction takes a second one) |
| `SqlConfig.outbox_retention` | 7d | Sent outbox rows |
| `SqlConfig.processed_retention` | 30d | Processed-event markers |
| `SqlConfig.external_call_retention`, `SqlConfig.saga_ended_retention`, `SqlConfig.failed_retention` | 30d | External calls after their last update, ended sagas, what failed for good |
| `SqlConfig.saga_dispatch_retention`, `SqlConfig.deadline_retention` | 7d | Dispatched saga entries, fired or cancelled deadlines |

`SqlConfig.from_env()` reads the URL, driver, notify and purge interval and leaves the rest at their defaults.
`SNODRA_STORE_INIT_SCHEMA` (the core variable) decides whether `App.start()` applies V1 or checks the schema.
The package is `snodra-messaging-sql`; the full Python settings are in
[Python configuration](/docs/messaging/python/configuration/#sql-sqlconfigfrom_env).

The schema is the published layout: [`V1__snodra.sql` for PostgreSQL](/docs/library-authors/sql/v1/postgresql/V1__snodra.sql)
and [`V1__snodra.sql` for MySQL](/docs/library-authors/sql/v1/mysql/V1__snodra.sql), byte-identical in
every add-on and checked against its published SHA-256.

## Guarantees

- **Joins the service's transaction.** `DataSourceTransactionManager` and `JpaTransactionManager`
  both bind the connection, so a business write, the outbox entry and the marker commit together.
  In Rust the crate takes the service's transaction through its own helper. In Go `store.Begin`
  returns a context carrying the transaction and `store.Tx` returns its `*sql.Tx` for the service's
  own writes; `store.WithTx` and `store.WithConn` bind a transaction or connection the service
  began. In Python `async with store.transaction():` binds the transaction to the context, and
  `store.transaction(conn=conn)` binds a connection the service began. A store call outside a
  transaction runs in a short READ COMMITTED transaction of its own.
- **One schema per logical service.** The tables are `snodra_outbox`, `snodra_processed_events`,
  `snodra_dead_letters`, `snodra_processor_control`, `snodra_external_calls`, `snodra_sagas`,
  `snodra_saga_associations`, `snodra_saga_dispatch`, `snodra_deadlines` and `snodra_saga_failures`
  (plus `snodra_schema`). Every column and stored value is shared with the other libraries, so any
  of them can share one database.
- **Safe competing relays.** Claims use `SELECT ... FOR UPDATE SKIP LOCKED`; a crashed claimer's rows
  are claimed again after its lease.
- **PostgreSQL wake-up.** `pg_notify('snodra_outbox', '')` runs inside the append's transaction, so a
  rollback sends nothing and a commit wakes the relay at once.
- **No silent truncation.** A missing STRICT mode, an old server, MariaDB or a one-connection pool
  fails the startup with a message naming what is supported.
- **Level 3 ports.** The Go (0.6.0) and Python (0.7.0) stores implement the outbox, the processed-event markers, the
  dead letters and the processor control; their external-call and saga ports return `ErrUnsupported` in Go and raise
  `MessageStoreUnsupported` in Python (the official add-ons implement every port by level 4).

The schema files are versioned (`V1__snodra.sql`) and the schema is applied once at startup unless
the service runs its own migration. The Go store embeds the published files and checks their SHA-256
values; `InitSchema` takes the shared database lock, so instances of any library starting together
apply V1 once.

## Capabilities

| Port | Kotlin | Rust | Go | Python |
|---|---|---|---|---|
| Outbox | yes | yes | yes | yes |
| Processed events | yes | yes | yes | yes |
| Dead letters | yes | yes | yes (0.6.0) | yes (0.7.0) |
| Processor control | yes | yes | yes (0.6.0) | yes (0.7.0) |
| External calls | yes | yes | no (level 4) | no (level 4) |
| Sagas | yes | yes | no (level 4) | no (level 4) |

## Read next

- The full SQL add-on reference: [the messaging model](/docs/messaging/).
- Kotlin settings: [Kotlin configuration](/docs/messaging/kotlin/configuration/).
- The Go settings and API: [Go configuration](/docs/messaging/go/configuration/#sql-sqlfromenv) and
  [Go events](/docs/messaging/go/api/#events).
- The Python settings and API: [Python configuration](/docs/messaging/python/configuration/#sql-sqlconfigfrom_env) and
  [Python events](/docs/messaging/python/api/#events).
- The other message store: [MongoDB](/docs/add-ons/mongodb-message-store/).
- The transaction guarantee: [Consistency](/docs/concepts/consistency/).

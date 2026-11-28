---
title: "Configuration"
---

Every setting is a field of `snodra.Settings` (`service`, `hubs`, `max_concurrent`, ...). `snodra.Settings.from_env()`
reads the `SNODRA_*` variables, the same ones the Rust and Go libraries read; the Kotlin library is configured with Spring
properties (`snodra.messaging.*`) instead. The add-ons read their own variables through a `from_env()` of their own
([Add-ons](#add-ons)). Keyword arguments passed to `from_env()` override what the environment set.

A variable that is unset, or blank, changes nothing. Numbers are non-negative integers; flags are `true`, `1`, `yes`,
`on`, `false`, `0`, `no` or `off`, in any letter case. In `Settings`, duration fields are numbers of seconds (floats),
while the environment variables use milliseconds (`_MS`). A value that does not parse, or is out of range, raises
`snodra.ConfigurationError`.

## Configuration (`snodra.Settings.from_env`)

| Variable | `Settings` field | Default | Meaning |
|---|---|---|---|
| `SNODRA_SERVICE_NAME` | `service` | required | the hub `service_name`: the logical name of the service, for example `orders-service` |
| `SNODRA_INSTANCE_ID` | `instance` | a random UUID | the instance id, unique per process (a pod name, for instance); a `Register` whose id is held by another service is refused |
| `SNODRA_SERVER_ADDRESS` | `hubs` | `("static://snodra-server:7000",)` | the hubs: a tuple of `host:port` (a `static://` prefix is accepted, an `http(s)://` one is refused), or one `dns:///name:port` whose every address is a hub, resolved again every 30 s; see [Several hubs](/docs/messaging/python/api/#several-hubs) |
| `SNODRA_SERVER_STATUS_INTERVAL_MS` | `status_interval` | 5.0 (5000 ms) | how often every acknowledged hub gets an `InstanceStatus`, which also goes out at once whenever the acknowledged hubs change; at least 1 ms |
| `SNODRA_MAX_CONCURRENT_HANDLERS` | `max_concurrent` | 256 | handlers run at once, at least 1; also the permits offered to the hubs, which queue further requests for this instance |
| `SNODRA_RECONNECT_BACKOFF_MIN_MS`, `SNODRA_RECONNECT_BACKOFF_MAX_MS` | `reconnect_backoff` | `(0.5, 5.0)` (500 ms, 5000 ms) | the wait between two attempts to reach a hub: the minimum, doubling up to the maximum, each wait jittered by +/-20 % and never above the maximum; back to the minimum once an attempt reached the `RegisterAck`; a refused `Register` waits 80 to 100 % of the maximum |
| `SNODRA_SERVER_LOAD_FACTOR` | `load_factor` | 100 | `Register.load_factor`: the instance's relative capacity; `0` reads as 100 |
| `SNODRA_SERVER_TAGS` | `tags` | none | `Register.tags`, `key=value,key=value`: unkeyed requests prefer instances whose tags match more of the sender's |
| `SNODRA_SERVER_REQUEST_TIMEOUT_MS` | `default_timeout` | none | the timeout of every `send` and `query` that sets none, sent as `Request.timeout_ms` (in seconds in `Settings`); a per-call `timeout` wins over it. With none, the hub applies its per-type override or its default (5 s); `0` is none |
| `SNODRA_SERVER_PRIORITIES` | `priorities` | none | the default `Request.priority` per sent type, `type=n,type=n` (higher first while the target's queue at the hub is not empty); a per-call `priority` wins |
| `SNODRA_SERVER_RETRY_ENABLED` | `default_retry` | none | `true` sets the default retry policy from the four variables below; `false` leaves no retry unless a call sets `retry`, which wins per call |
| `SNODRA_SERVER_RETRY_MAX_ATTEMPTS` | `RetryPolicy.max_attempts` | 3 | attempts in all, the first included; at least 1 (1 is no retry) |
| `SNODRA_SERVER_RETRY_INITIAL_BACKOFF_MS`, `SNODRA_SERVER_RETRY_MULTIPLIER`, `SNODRA_SERVER_RETRY_MAX_BACKOFF_MS` | `RetryPolicy` | 0.1, 2.0, 2.0 (100 ms, 2.0, 2000 ms) | the wait before the second attempt, the growth factor (a finite number of at least 1) and the cap of one wait; each wait is jittered by +/-20 % and never above the cap. The policy variables are checked even while retry is off |
| `SNODRA_SERVER_STREAM_CREDIT_TIMEOUT_MS` | `stream_credit_timeout` | 600.0 (600000 ms) | how long a streaming handler waits for the caller's credit before the stream ends with `TIMEOUT` and the handler's task is cancelled (the default is the hub's default maximum stream duration, 10 min); at least 1 ms |
| `SNODRA_SERVER_MAX_SUBSCRIPTIONS` | `max_subscriptions` | 1024 | the most subscription queries this instance serves at once; one more is refused with `RESOURCE_EXHAUSTED`; at least 1 |
| `SNODRA_JWKS_URL`, `SNODRA_ISSUER` | `jwks_url`, `issuer` | unset | set both to verify forwarded tokens (RS256 signature, issuer, expiry); the issuer is required with the URL. Unset: no token is an identity (every caller is anonymous), a guarded handler cannot be registered, and a warning is logged once |
| `SNODRA_SECURITY_ROLES_CLAIM` | `roles_claim` | `roles` | where a token's roles are read: a dotted path to a list of strings (`realm_access.roles`, `groups`), or `scope` for space-separated scopes |
| `SNODRA_SERVER_ALWAYS_ROUTE_THROUGH_HUB` | `always_route_through_hub` | false | `true` sends every `send` and `query` through a hub, also one of a type this instance handles itself; `false` answers a command, or a query that is not shared, of an own type in-process ([API](/docs/messaging/python/api/#requests-answered-in-process)) |
| `SNODRA_FORWARD_JWT` | `forward_jwt` | true | whether a request sent while handling one carries the handled request's token, so that the downstream handler acts for the same user |
| `SNODRA_SERVER_TOKEN` | `credentials` with `Token` | none | the static access token sent in `Register.credentials.token` on every hub stream; needed when the hub enforces access control; never logged |
| `SNODRA_SERVER_TOKEN_FILE` | `credentials` with `TokenFile` | none | a file holding the token, for mounted secrets; **wins over `SNODRA_SERVER_TOKEN`**; surrounding whitespace is ignored; read again before every connection and on every heartbeat, so a rotated secret needs no restart |
| `SNODRA_SERVER_OAUTH2_TOKEN_URI` | `credentials` with `ClientCredentials` | none | turns JWT authentication on: the provider's token endpoint; needs a client secret; see [Authenticating with a JWT](#authenticating-with-a-jwt) |
| `SNODRA_SERVER_OAUTH2_CLIENT_ID` | `ClientCredentials.client_id` | the service name | the OAuth2 client id; it must be the service name (the hub checks the token's `azp` against it) |
| `SNODRA_SERVER_OAUTH2_CLIENT_SECRET`, `SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE` | `ClientCredentials.client_secret`, `.client_secret_file` | none | the client secret, or a file holding it, **which wins** and is read at every token fetch; one of them is required with the token URI |
| `SNODRA_SERVER_OAUTH2_SCOPE`, `SNODRA_SERVER_OAUTH2_CA` | `ClientCredentials.scope`, `.ca_file` | none | the `scope` sent with the grant (space-separated); a PEM file of extra root certificates for the token endpoint, beside the system's |
| `SNODRA_SERVER_TLS` | `tls` (`TLSConfig`) | none | `true` makes every hub connection TLS (1.2 or later); needed when the hub serves TLS |
| `SNODRA_SERVER_TLS_CA` | `TLSConfig.ca_file` | bundled roots | PEM file with the CA that signs the hubs' certificates, read again at every connection; needs TLS (`SNODRA_SERVER_TLS=true`, or a client certificate) |
| `SNODRA_SERVER_TLS_SERVER_NAME` | `TLSConfig.server_name` | the host of each hub address | the name the hubs' certificates must carry, also sent as SNI; needs TLS (`SNODRA_SERVER_TLS=true`, or a client certificate) |
| `SNODRA_SERVER_TLS_CLIENT_CERT`, `SNODRA_SERVER_TLS_CLIENT_KEY` | `client_certificate` (`ClientCertificate`) | none | the client certificate chain (leaf first) and its private key, PEM, for mutual TLS; both or neither; **they turn TLS on**; see [Authenticating with a client certificate](#authenticating-with-a-client-certificate-mtls) |

### Events

| Variable | `Settings` field | Default | Meaning |
|---|---|---|---|
| `SNODRA_EVENTS_SOURCE` | `events_source` | `snodra.events` | the event store's source the service publishes its events to and every processor reads; one source for both |
| `SNODRA_OUTBOX_ENABLED` | `outbox_enabled` | true | every instance runs the outbox relay; `false` on every instance stops the service's events being published, `false` on all but one keeps the order per key of what one instance publishes |
| `SNODRA_OUTBOX_POLL_INTERVAL_MS` | `outbox_poll_interval` | 0.2 (200 ms) | the relay's longest wait between two claims of the outbox (at least 1 ms); a committed append may wake it sooner |
| `SNODRA_OUTBOX_BATCH_SIZE` | `outbox_batch_size` | 100 | the most outbox entries one claim returns (at least 1) |
| `SNODRA_OUTBOX_MAX_ATTEMPTS` | `outbox_max_attempts` | 10 | sends of one outbox entry in all before it is marked failed (at least 1) |
| `SNODRA_OUTBOX_LEASE_MS` | `outbox_lease` | 120.0 (120000 ms) | how long a claimed outbox batch stays one relay's; it must be longer than a send (40 s). A crashed relay's entries are claimed again after the lease |
| `SNODRA_CONSUMER_ENABLED` | `consumer_enabled` | true | every instance reads its event processors' subscriptions; a tool that only publishes turns it off |
| `SNODRA_CONSUMER_MAX_ATTEMPTS` | `consumer_max_attempts` | 5 | event handler invocations per delivered record in all, the first included (at least 1); after them the record becomes a dead letter ([Dead letters](#dead-letters)) |
| `SNODRA_STORE_INIT_SCHEMA` | `store_init_schema` | true | `start` applies or creates the message store's schema; `false` checks it instead, for a service that runs its own migrations |

Options passed to `App` with no environment variable: `store` and `event_store` (the stores themselves, see
[Add-ons](#add-ons)), `codec` (the payload codec, `JsonCodec` by default), `telemetry` (see
[API](/docs/messaging/python/api/#telemetry)) and, per call on `send`, `query`, `gather`, `stream` and `subscribe`:
`timeout`, `retry`, `routing_key`, `priority`, `headers`, `initial_credit` and `max_results`.

### Dead letters

| Variable | `Settings` field | Default | Meaning |
|---|---|---|---|
| `SNODRA_EVENTS_DEAD_LETTER_MODE` | `dead_letter_mode` | `collection` | where a record that exhausted its attempts goes: `collection` (the message store's dead letters), `event-store` (the event store's dead-letter source `<source>.dlt`, which needs its `native-dead-letter` capability) or `log` (logged and skipped) |
| `SNODRA_EVENTS_DEAD_LETTER_RETENTION_MS` | `dead_letter_retention` | 30 days (2592000000 ms) | how long a dead letter is kept, at least 1 s; written as the letter's `expire_at_ms`, and the store's retention removes it |

### Processor control and reset

There is no variable for the control state: it lives in the message store's processor-control port (`store.control`)
and every instance reads it at start and every 5 s. The clocks are fixed too, as the protocol gives them: a reset
prepare asks for a lease of at least 1 s, an executing reset renews it every 10 s (at most a third of it), an execute
stops itself after 120 s, a processor stays `FAILING` for 60 s after a record exhausted its attempts, dead-letter counts
are sampled every 30 s (and after a park), and a dead letter's publish in mode `event-store` is given 30 s before the
record is delivered again.

### Sagas, deadlines and external calls

The level-4 runtime has no `SNODRA_*` variable and no `Settings` field yet; it runs with the library's fixed timings.
The dispatch poll and lease are Python's own — 0.2 s and 60 s, where Kotlin and Go default to 0.5 s and a 30 s base
lease:

| Setting | Value | Meaning |
|---|---|---|
| `saga_stage_max_attempts` | 5 | Attempts of one (event, saga type) on a version or start-key conflict |
| `saga_stage_initial_backoff`, `saga_stage_max_backoff` | 0.2 s, 5 s | The wait after a conflict doubles from the first to the second, jittered by ±20 % |
| Saga handler attempts | 2 | Attempts of a handler that fails, 50 ms apart; then the event is parked in `saga_failures` |
| `saga_dispatch_poll` | 0.2 s | How often the relay looks for sagas with a pending entry |
| `saga_dispatch_batch` | 100 | Sagas with a pending entry one pass reads; each runs as its own task |
| `saga_dispatch_lease` | 60 s | How long one relay holds a saga's `seq` order |
| `saga_dispatch_send_timeout` | 60 s | The longest one send is waited for; a send that ignores cancellation is abandoned |
| `saga_dispatch_max_attempts` | 10 | Sends of one command before `EXHAUSTED` |
| `saga_dispatch_initial_backoff`, `saga_dispatch_max_backoff` | 1 s, 300 s | The wait between attempts doubles, jittered by ±20 % |
| `saga_notice_max_attempts` | 10 | Deliveries of one `SagaCommandFailed` before it is logged and dropped |
| `deadline_poll`, `deadline_lease` | 1 s, 30 s | How often due deadlines are looked for, and how long a claim holds |
| `external_call_lease` | 300 s | How long an `IN_PROGRESS` adapter call may take before its outcome is unknown |

A dispatch lease, a deadline claim and an external-call lease are timestamps one instance writes and another compares
with its own clock: keep the instances' clocks in step (NTP or the platform's time sync). See
[API](/docs/messaging/python/api/#sagas-and-deadlines) and
[API](/docs/messaging/python/api/#idempotent-external-calls) for what each setting bounds.

## Add-ons

The core reads the variables above. An add-on has a `from_env()` of its own, and the service hands the result to the
add-on: `KafkaEventStore(KafkaConfig.from_env())`, `SqlStore(SqlConfig.from_env())`, `MongoStore(MongoConfig.from_env())`
and `RabbitMQEventStore(RabbitMQConfig.from_env())`. An add-on reads its variables only when the service calls its
`from_env()`; having them in the environment changes nothing by itself. The store is then passed to `snodra.App` with
`event_store=` or `store=`. A service needs one event store and one message store; there is no classpath, so the choice
is in code.

### Kafka (`KafkaConfig.from_env`)

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_KAFKA_BOOTSTRAP` | `kafka:19092` | the brokers, `host:port` entries separated by commas; required |

`KafkaConfig.from_env()` returns the configuration with the bootstrap servers. The other settings are fields of
`KafkaConfig`: `client_id` (`"snodra-messaging"`), `request_timeout_ms` (30 000 ms), `session_timeout_ms` (10 000 ms),
`max_poll_records` (100), `status_refresh` (1.0 s), `admin_timeout` (10.0 s); the store sets the group, the topic, the
reset offset, the group protocol, the partitioner and the commit behavior itself. See
[Kafka event store](/docs/add-ons/kafka-event-store/).

### SQL (`SqlConfig.from_env`)

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_STORE_SQL_URL` | required | the database: `postgres://user:password@host:port/database?params`, `postgresql://...`, or `mysql://user:password@host:port/database?params` |
| `SNODRA_STORE_SQL_DRIVER` | from the URL's scheme | `postgres` or `mysql`; set it when the URL does not say |
| `SNODRA_STORE_SQL_NOTIFY` | true | PostgreSQL: an append sends `pg_notify` in its transaction and the relay listens, so a commit wakes it at once; `false` polls. Turn it off behind PgBouncer in transaction mode. MySQL always polls |
| `SNODRA_STORE_SQL_PURGE_INTERVAL_MS` | 60000 | how often the retention purge runs; `0` or negative turns the purge off |

The connection pool (`min_size` 1, `max_size` 10, at least two connections) and retentions are fields of `SqlConfig`
(outbox 7 days, processed markers 30 days, and the later ports' retentions). See
[SQL message store](/docs/add-ons/sql-message-store/).

### MongoDB (`MongoConfig.from_env`)

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_STORE_MONGO_URI` | required | `mongodb://...` or `mongodb+srv://...`; the database must be a replica set (a single-node one is enough), because the store joins the service's transaction |
| `SNODRA_STORE_MONGO_DATABASE` | required | the service's database, which holds the shared collections |

The retentions are fields of `MongoConfig`. A service that already owns an `AsyncMongoClient` passes it to
`MongoStore(config, client=...)` instead. See [MongoDB message store](/docs/add-ons/mongodb-message-store/).

### RabbitMQ Streams (`RabbitMQConfig.from_env`)

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_RABBITMQ_HOSTS` | `rabbitmq` | the nodes to try first, `host` or `host:port`, comma-separated |
| `SNODRA_RABBITMQ_PORT` | 0 (5552, or 5551 with TLS) | the port of a host given without one |
| `SNODRA_RABBITMQ_VIRTUAL_HOST` | `/` | the virtual host; empty reads as `/` |
| `SNODRA_RABBITMQ_USERNAME`, `SNODRA_RABBITMQ_PASSWORD` | `guest` | the user and its password; the password is never logged |
| `SNODRA_RABBITMQ_TLS` | false | `true` connects with TLS 1.2 or later, verified against the system roots or `tls_ca_file` |
| `SNODRA_RABBITMQ_MANAGEMENT_URL` | none | the management API's root (`http://rabbitmq:15672`, no credentials in it); setting it declares `replay`, and `RabbitMQEventStore` checks the API once at startup |

The management API's own login (`RabbitMQConfig.management_username`, `management_password`) defaults to the stream user's;
`management_timeout` is 5.0 s, `confirm_timeout` 30.0 s, `request_timeout` 10.0 s, `offset_store_messages` 10 000,
`offset_store_interval` 5.0 s, and `status_refresh` 2.0 s. See
[RabbitMQ Streams event store](/docs/add-ons/rabbitmq-streams-event-store/).

### Event stores and message stores

An event store publishes the service's events and serves its processors' subscriptions; a message store holds the
outbox, the processed-event markers, the dead letters, the processor control state, the external-call records and the
saga records. The in-memory ones, `snodra.MemoryEventStore()` and `snodra.MemoryStore()`, are for tests and local runs:
nothing survives the process, and `start` warns once for each. A service that only handles commands, queries and
subscription queries needs neither store and starts without them; a saga needs both, even with no event handler, and
an idempotent command handler needs the message store only.

## Credentials

At most one kind of credential is used: a token, a JWT, or a client certificate. Setting two kinds raises
`ConfigurationError` when building `Settings` or `App`. Everything here is opt-in and the hub decides: against a hub
whose access control is off, the credentials are ignored.

### Token

`snodra.Token` (or `SNODRA_SERVER_TOKEN`) sets the service's static token, sent in `Register.credentials.token` of
every stream to every hub and nowhere else. A blank token is none.

`snodra.TokenFile` (or `SNODRA_SERVER_TOKEN_FILE`) names a file holding the token, the way container secrets arrive
(`/run/secrets/...`). Building `App` fails when the file cannot be read or is empty. Later it is read again before
every connection and on every heartbeat of a registered stream; a changed token is sent to the hub as a credentials
refresh. A file that cannot be read or is empty later keeps the last token read. Prefer an atomic swap: write a new file
and rename it over the old one.

### Authenticating with a JWT

`ClientCredentials` (or `SNODRA_SERVER_OAUTH2_*`) registers the instance with an access token from an OAuth2
client-credentials grant (the client is authenticated with HTTP Basic, the request takes 10 s at most and follows no
redirect):

```python
settings = snodra.Settings(
    service="orders-service",
    hubs=("hub.example.test:7000",),
    tls=snodra.TLSConfig(),
    credentials=snodra.ClientCredentials(
        token_url="https://idp.example.test/oauth2/token",
        client_id="orders-service",
        client_secret_file="/run/secrets/orders-service-secret",
    ),
)
app = snodra.App(settings)
```

- The token is renewed before it expires: when a margin of a fifth of its lifetime is left, at least 5 s and at most
  half the lifetime (so at 80 % of a long lifetime, and at half of a 10 s one). A new token is sent once on every
  registered stream as a credentials refresh.
- A failed renewal keeps the token and is retried after 1 s, doubling up to 30 s.
- A stream the hub closes with `UNAUTHENTICATED` drops the token it presented, so the next one registers with a new
  token; `PERMISSION_DENIED` keeps it.
- When no token can be had, no stream is opened: the failure is the latest `app.rejection` and the attempt is retried at
  the reconnect backoff.
- Any object implementing `TokenSource` (`async def token(self) -> AccessToken`) can be passed to `credentials` instead.

### Authenticating with a client certificate (mTLS)

`snodra.ClientCertificate(cert_file, key_file)` makes the instance present a client certificate to the hubs. The leaf
must carry exactly one URI SAN `snodra://service/<name>` naming the service; `App` checks the pair on startup. The files
are read at every connection and every 3 s: a renewed valid pair is rolled over to before the presented certificate expires,
one hub at a time, after a short random delay. A pair that cannot be used keeps the one presented.

### Credentials in logs

`AccessToken`, `ClientCredentials` and `Token` hide their secrets when converted to text (`str` and `repr`). Do not
serialize these values into logs or unencrypted stores.

### Rejections

A hub that refuses a `Register` (`ALREADY_EXISTS` for a type another service owns, `INVALID_ARGUMENT`,
`UNAUTHENTICATED`, `PERMISSION_DENIED`) is not an outage: the instance keeps running and retries at the backoff cap
(80 to 100 % of the maximum). `app.rejection` returns the latest refusal and is not cleared by a later acceptance. Fix
the token or the access rules and the next attempt succeeds on its own.

## Verifying forwarded tokens

With `jwks_url` and `issuer` (or `SNODRA_JWKS_URL` and `SNODRA_ISSUER`), every forwarded token is checked, before a handler
runs, for its RS256 signature against the issuer's keys, its issuer and its expiry; a token that fails is answered
`UNAUTHENTICATED`, also when the keys cannot be fetched. Without it, no token is an identity: every caller is anonymous,
the token only goes on with the requests the handler sends, and registering a handler with a guard
(`authenticated()`, `role()`, `caller_matches()`) raises `ConfigurationError`. A header that is not a bearer token, or a
token that is not a signed JWS (unreadable, `alg: none`, an empty signature, an encrypted token), is answered
`UNAUTHENTICATED` with or without a JWKS.

# Configuration

## Configuration

```yaml
snodra:
  messaging:
    service-name: workouts          # Kafka consumer group, event source, hub registration
    type-prefix: workouts           # wire type prefix for classes without @MessageType
    hub:
      address: static://snodra-server:7000
    kafka:
      bootstrap-servers: broker:19092
spring:
  mongodb:
    uri: mongodb://mongo:27017/workouts   # Spring Boot 4 key; spring.data.mongodb.uri is no longer bound
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://auth.example/realms/snodra
```

The `issuer-uri` is only needed when the service also serves HTTP or wants forwarded tokens verified (see
[Security](#security)); Kafka-only tools and services behind the hub start without any security configuration.

All keys (`snodra.messaging.*`; durations accept `200ms`, `5s`, `7d`; relaxed binding, e.g. `SNODRA_MESSAGING_HUB_ADDRESS`):

| Key | Default | Meaning |
|---|---|---|
| `service-name` | required | Kafka consumer group, event `source`, hub `Register.service_name`. |
| `type-prefix` | required | Prefix of the wire type name for message classes without `@MessageType`. |
| `hub.enabled` | `true` | Connect to the hub and expose the hub-backed `CommandBus`/`QueryBus` (addition beyond the spec table). |
| `hub.address` | `static://snodra-server:7000` | The hub or hubs: one gRPC target (`host:port`, optional `static://` prefix), a comma-separated list of them (`hub-1:7000,hub-2:7000`, one connection per hub), or one `dns:///name:port` whose addresses are re-resolved every 30 s. See [Multiple hubs](api.md#multiple-hubs). A malformed value fails the startup. |
| `hub.status-interval` | `5s` | Period of the `InstanceStatus` report (connected hub ids, handlers in flight) sent to every live hub; also sent whenever the set of live hubs changes. Must be positive. |
| `hub.request-timeout` | unset | Per-request timeout sent as `timeout_ms`. Unset: the hub applies its default (5 s) or its per-type override (`SNODRA_SERVER_TIMEOUT_OVERRIDES`). Also bounds the wait for a hub stream (5 s when unset). `0s` counts as unset. |
| `hub.reconnect-backoff.min` | `500ms` | Initial reconnect delay when the stream drops; doubles per failed attempt. Must be positive and not above `max`, or the startup fails naming the property. |
| `hub.reconnect-backoff.max` | `5s` | Maximum reconnect delay. Every wait is jittered by ±20 % and capped at this value (at the cap: 80-100 % of it); the delay resets to `min` once an attempt reached the hub's handshake. Must be positive (a zero would hot-loop handshakes against a refusing hub): checked at binding, a bad value fails the startup naming the property. |
| `hub.max-subscriptions` | `1024` | Subscription queries this instance serves at once, over every hub (at least 1). The next one is refused with `RESOURCE_EXHAUSTED` ("subscription limit (N) reached"), which the subscriber sees as a `HandlerBusyException`. A subscription holds no handler permit, so `max-concurrent-handlers` does not bound it; the default equals the hub's own `SNODRA_SERVER_MAX_SUBSCRIPTIONS_PER_INSTANCE`. |
| `hub.stream-credit-timeout` | `10m` | The longest a streaming handler of this instance waits for credit from the collector before it ends the stream with `TIMEOUT` ("no credit within ...") and frees its handler slot and hub permit (a hub that forgot the stream would otherwise leave them held forever). Must be positive; the default is the hub's default maximum stream duration (`SNODRA_SERVER_MAX_STREAM_DURATION`). |
| `hub.token` | none | Static token sent in `Register.credentials.token` of **every** hub stream (hub access control, [Hub security](#hub-security-token-acl-and-tls)). Optional; an empty or blank value is the same as none. Never logged, redacted in `toString` and in the actuator's `configprops` and `env`. Environment: `SNODRA_MESSAGING_HUB_TOKEN`, or `SNODRA_SERVER_TOKEN` when this key is unset. |
| `hub.token-file` | none | File holding the token (a container secret such as `/run/secrets/snodra-server-token`; surrounding whitespace ignored). Read at startup (an unreadable file fails it, naming the file) and **again on every reconnect**, so a rotated secret is picked up without a restart. After a first non-empty read, an unreadable or empty file (a non-atomic rotation caught half way) keeps the last token read and logs one `WARN`; at startup an empty file means no token. **Wins over `hub.token` when both are set.** Environment: `SNODRA_MESSAGING_HUB_TOKEN_FILE`, or `SNODRA_SERVER_TOKEN_FILE` when this key is unset. |
| `hub.tls.enabled` | `false` | Talk TLS to the hub, for every `hub.address` form (a list of targets and `dns:///`). Off: plain text. The hub must serve TLS on that port (`SNODRA_SERVER_TLS_CERT` / `SNODRA_SERVER_TLS_KEY`). |
| `hub.tls.ca-file` | JVM system roots | PEM file with the CA certificate(s) that signed the hub's certificate (a self-signed hub certificate is its own CA). Read on every connection attempt; a file that cannot be used fails the startup. Set without `hub.tls.enabled` it is ignored with a warning. |
| `hub.tls.server-name` | the address's host | Name to verify the hub's certificate against, for when the address is an IP or an alias the certificate does not list. |
| `hub.oauth2.token-uri` | none | Setting it turns OAuth2 client-credentials authentication on (see [JWT](#authenticating-with-a-jwt-oauth2-client-credentials)): the token endpoint, for example `https://auth.example/realms/snodra/protocol/openid-connect/token`. `http` is allowed and warns once unless the host is loopback or a single-label name. Cannot be combined with `hub.token` or `hub.token-file` (the startup fails naming both). Environment: `SNODRA_MESSAGING_HUB_OAUTH2_TOKEN_URI`, or `SNODRA_SERVER_OAUTH2_TOKEN_URI` when this key is unset. |
| `hub.oauth2.client-id` | `snodra.messaging.service-name` | The confidential client's id; it is the token's `azp`, which the hub requires to equal the service name. Environment: `SNODRA_SERVER_OAUTH2_CLIENT_ID`. |
| `hub.oauth2.client-secret` | none | The client secret (sent as HTTP Basic, `client_secret_basic`). Never logged, redacted in `toString` and in the actuator's `configprops` and `env`. Prefer the file. Environment: `SNODRA_MESSAGING_HUB_OAUTH2_CLIENT_SECRET`, or `SNODRA_SERVER_OAUTH2_CLIENT_SECRET`. |
| `hub.oauth2.client-secret-file` | none | File holding the client secret: read at startup (an unreadable or empty file fails it, naming the file) and **again on every token fetch**, so a rotated secret applies without a restart. Wins over `client-secret`. Environment: `SNODRA_MESSAGING_HUB_OAUTH2_CLIENT_SECRET_FILE`, or `SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE`. A token URI with neither secret fails the startup. |
| `hub.oauth2.scope` | none | `scope` of the token request, sent as written (space-separated). Environment: `SNODRA_SERVER_OAUTH2_SCOPE`. |
| `hub.oauth2.ca-file` | platform roots | PEM CA certificate(s) trusted **on top of** the platform roots for an `https` token URI (not the hub's CA, which is `hub.tls.ca-file`). A file that cannot be used fails the startup. Environment: `SNODRA_SERVER_OAUTH2_CA`. |
| `hub.max-concurrent-handlers` | `256` | Incoming hub requests handled concurrently by this instance, over all hubs (at least 1, else the startup fails); further requests wait for a free slot. Also announced as `initial_permits` to a hub with flow control (split over N hubs: `ceil(max / N)` each), which then queues the excess on its side. |
| `hub.load-factor` | `100` | Relative capacity of this instance (`Register.load_factor`); weights its share of the hub's routing (keyed ring and load score). A negative value fails the startup; 0 is allowed (the hub reads it as 100). |
| `hub.tags.<name>` | none | Labels announced in `Register.tags`, for example `hub.tags.zone=eu-1`; unkeyed requests prefer instances whose tags match the sender's. |
| `hub.priorities.<type>` | none (0) | Default `Request.priority` per message type, for example `hub.priorities.orders.PlaceOrder=5`; higher is served first when the hub queues requests for a busy handler. `SendOptions.priority` wins. |
| `hub.retry.enabled` | `false` | Retry failed sends that are safe to retry (see "Retry" below). `SendOptions.retry` overrides per call. |
| `hub.retry.max-attempts` | `3` | Total attempts including the first (1 = no retry). The `hub.retry.*` values are validated at startup even while `enabled` is false: `max-attempts` < 1, `multiplier` < 1 or a negative backoff fails it. |
| `hub.retry.initial-backoff` | `100ms` | Wait before the second attempt. Every wait is jittered by ±20 % and capped at `max-backoff` (at the cap: 80-100 % of it). |
| `hub.retry.multiplier` | `2` | Growth of the wait per further attempt. |
| `hub.retry.max-backoff` | `2s` | Upper bound of a single wait. |
| `kafka.bootstrap-servers` | `broker:19092` | Kafka bootstrap servers. |
| `kafka.topic` | `snodra.events` | Events topic. |
| `kafka.consumer.enabled` | `true` | Set `false` in tools that only publish. |
| `kafka.group-id` | `service-name` | The service's consumer group: every event processor, `default` included, uses `<this>.<name>`. See [Event processors](api.md#event-processors). |
| `kafka.consumer.max-attempts` | `5` | Handler invocations per record (first try included, 1 s apart) before the record goes to the dead letters; shared by every processor. |
| `kafka.dead-letter.mode` | `collection` | What a processor does with a record it cannot handle: `collection` (park it in `dead_letters`, sequence its key, `DeadLetters` admin API), `topic` (produce it to `<topic>.dlt`) or `log` (log and skip: nothing is parked). Case-insensitive; anything else fails the startup. See [Dead letters](api.md#dead-letters). |
| `kafka.dead-letter.retention` | `30d` | A letter is deleted this long after it was parked (TTL index on `expireAt`), which also unblocks its key. At least `1s`. |
| `outbox.enabled` | `true` | Run the outbox publisher that relays `outbox` documents to Kafka. |
| `outbox.poll-interval` | `200ms` | Outbox poll period. |
| `outbox.batch-size` | `100` | Documents per poll. |
| `outbox.retention` | `7d` | Sent outbox documents older than this are deleted (TTL index). |
| `outbox.max-attempts` | `10` | Send attempts per outbox document before it is marked failed (`failedAt`) and skipped. |
| `idempotency.retention` | `30d` | `processed_events` documents older than this are deleted (TTL index). |
| `security.forward-jwt` | `true` | Put the current request's bearer token in the hub request's `authorization` header. |
| `sagas.enabled` | `true` | Switch for the saga runtime, the dispatch relay and the deadline scheduler. They exist only when the application has a `@Saga` class (found by scanning its packages) anyway. See [Sagas](api.md#sagas). |
| `sagas.max-attempts` | `5` | Attempts per saga event (first try included) for **conflicts** (a version check, a start-key duplicate, a Mongo write conflict or transient transaction error) before the event is parked in `saga_failures`; also the bound for firing a deadline. Backoff 200 ms doubling to 5 s (not configurable). A **handler exception** is not cured by waiting: it gets two attempts in all, at most 50 ms apart, and the event is then parked. |
| `sagas.ended-retention` | `30d` | Ended sagas are deleted this long after they ended (TTL index on `sagas.endedAt`). Must be positive. |
| `sagas.dispatch-retention` | `7d` | Dispatched `saga_dispatch` entries are deleted this long after they were sent (TTL index on `dispatchedAt`). Must be positive. |
| `sagas.relay.poll-interval` | `500ms` | How often the dispatch relay looks for entries that saga handlers recorded. Must be positive. |
| `sagas.relay.lease` | `30s` | How long a relay instance holds one saga's dispatch order before another instance may take over (a crashed instance's lease expires); renewed before each entry and, every third of the lease, while a send runs. Needs synchronised clocks (NTP) across instances. Must be positive. |
| `sagas.relay.max-attempts` | `10` | Attempts per command for transient failures (first try included, at least 1) before it becomes `SagaCommandFailed(EXHAUSTED)`. |
| `sagas.relay.initial-backoff` | `1s` | Wait before the second attempt of a command; doubles per attempt up to `max-backoff`. |
| `sagas.relay.max-backoff` | `5m` | Upper bound of one wait between attempts of a command. |
| `deadlines.poll-interval` | `1s` | How often the deadline scheduler looks for due deadlines. Must be positive. |
| `deadlines.lease` | `30s` | How long a claimed deadline stays reserved for the instance that claimed it; an expired claim lets it fire again (at least once). Must be positive. |
| `deadlines.retention` | `7d` | Fired and cancelled deadlines are deleted this long after (TTL index on `deadlines.finishedAt`). Must be positive. |
| `external.calls.enabled` | unset | Whether the idempotency interceptor and the `external_calls` indexes exist. Unset: they exist when a class in the application's packages has an `@IdempotentHandler` method. `true` when the adapter lives outside those packages, `false` to switch it off. |
| `external.calls.lease` | `5m` | How long an `IN_PROGRESS` external call may take before its outcome counts as unknown (a crash in the middle of the call). Must be positive. |
| `external.calls.retention` | `30d` | `external_calls` documents older than this are deleted (TTL index on `updatedAt`). Must be positive. |
| `external.kafka.sources.<name>.topic` | required | A partner's topic, consumed into local Snodra events (never republished to `snodra.events`). Each source needs an `ExternalRecordTranslator` bean named `<name>`; a source without one fails the startup naming it. |
| `external.kafka.sources.<name>.bootstrap-servers` | `kafka.bootstrap-servers` | The partner's cluster. |
| `external.kafka.sources.<name>.group-id` | `<service-name>.external.<name>` | The source's consumer group. |
| `external.kafka.sources.<name>.properties.*` | none | Extra consumer properties (for example `security.protocol`); bootstrap servers, group id, deserializers and auto-commit are fixed by the library: an entry for one of those keys fails the startup, naming it. `auto.offset.reset` is `earliest` unless set here. Record retries use `kafka.consumer.max-attempts`. |

## Security

(The hub's own access control, the service token and TLS are in [Hub security](#hub-security-token-acl-and-tls) below.)

Cross-service commands and queries are service-to-service calls on a private network, so they are **trusted by
default**: a request with no token is anonymous and is still handled. A handler that needs an authenticated user
opts in:

```kotlin
@CommandHandler
@RequiresAuthentication(expression = "hasRole('snodra-user')")
suspend fun handle(cmd: LogWorkout, ctx: MessageContext): LogWorkoutResult = ...

@QueryHandler
@RequiresAuthentication   // isAuthenticated()
fun handle(q: GetWorkout, ctx: MessageContext): GetWorkoutResult = ...

@CommandHandler
fun handle(cmd: RecomputeStats) { ... }   // no annotation: any caller, including event handlers and jobs
```

The expression is Spring Security SpEL evaluated by the **receiving** library before the handler runs:
`isAuthenticated()`, `hasRole('x')`, `hasAnyRole(...)`, `hasAuthority('ROLE_x')`, `principal` (a `MessagePrincipal`
with `userId`, `roles`, `verified`), plus `#message` (the decoded command or query) and `#ctx` (the `MessageContext`),
e.g. `"hasRole('snodra-user') and #message.ownerId == #ctx.userId"`. Realm roles from the token's `realm_access.roles`
become `ROLE_<role>` authorities. A syntax error fails startup naming the handler; `@RequiresAuthentication` is not
allowed on `@EventHandler` (events carry no identity). Annotated handlers are listed at startup at `INFO`.

Outcomes, on the hub path and the local short-circuit alike:

| Caller | Result at the sender |
|---|---|
| no identity (no token, or an event handler / job) | `UnauthenticatedException` (wire code `UNAUTHENTICATED`) |
| identity present, expression false or fails to evaluate | `AccessDeniedException` (wire code `PERMISSION_DENIED`) |
| identity present, expression true | handler runs |

A handler that throws `AccessDeniedException` (this library's or Spring's) also yields `PERMISSION_DENIED`, so a
nested send denied deeper in a chain reaches the original caller as `AccessDeniedException`.

How the receiver resolves the forwarded identity (`ForwardedIdentityResolver`):

| Forwarded `authorization` header | `JwtDecoder` bean | Result |
|---|---|---|
| absent | any | anonymous; `MessageContext.userId = null`, request proceeds |
| `Bearer <jwt>`, valid | present | identity `{sub, realm roles}`, `verified = true` |
| `Bearer <jwt>`, invalid or expired | present | `UNAUTHENTICATED` (a forged or stale token is a bug or an attack) |
| `Bearer <jwt>`, signed | absent | claims read **without verification**, `verified = false`; warned once per process |
| `Bearer <jwt>`, unsigned (`alg: none`) or encrypted | absent | `UNAUTHENTICATED` (only signed tokens are read unverified) |
| malformed | any | `UNAUTHENTICATED` |

an unverified identity counts as authenticated. The peer that forwarded it validated it at its own
ingress and is trusted by the network model; verification is for catching forged or expired tokens where the
service can, not for distrusting the peer. Without a `JwtDecoder` the checks are therefore advisory: any client on
the private network can mint a signed token with any claims. Use `principal.verified` in an expression when a
handler must insist on a verified identity (`"isAuthenticated() and principal.verified"`). On the local
short-circuit the current Spring `Authentication` is normalised the same way: `sub` and `realm_access.roles` are
read from the token (`JwtAuthenticationToken`, `BearerTokenAuthentication`), so `hasRole('x')` means the realm role
regardless of how the application maps authorities for its own REST endpoints.

Notes:

- `@RequiresAuthentication` is read from the handler method itself and is not inherited from an interface or
  superclass method.
- `permitAll()`, `denyAll()` and `isAnonymous()` are accepted syntax but meaningless here: an anonymous caller is
  rejected with `UNAUTHENTICATED` before any expression runs, so leave the annotation off a handler open to anyone.
- A string result such as `'true'` is not a grant; the expression must evaluate to the Boolean `true`.
- An expression that throws (for example `#message.owner.id` on a null `owner`) is a denial, not a handler error.

The resolved identity is installed in the `SecurityContext` while the handler runs, so `CallerContext` works inside
handlers and nested sends re-forward the same token. `snodra.messaging.security.require-jwt` was removed; setting it
fails startup with a hint.

## Hub security: token, ACL and TLS

The hub can authenticate services and restrict what they register and send, and serve its gRPC port over TLS
(operator how-to: `https://snodra.damoreira.com/concepts/security/`). All of it is opt-in
on the hub (`SNODRA_SERVER_AUTH_MODE=off|permissive|enforce`, default `off`); this section is the client's side. It is
unrelated to [Security](#security) above, which is about the **user's** forwarded JWT.

**The token.** Give each service its own random token (`openssl rand -hex 32`) and the same one in the hub's ACL file
(which holds only its SHA-256):

```yaml
snodra:
  messaging:
    hub:
      token: ${BILLING_HUB_TOKEN}            # or: token-file: /run/secrets/snodra-server-token
```

The token goes in `Register.credentials.token` of every stream (read once per stream; the hub reads it from the first
`Register` only). It is never logged, `HubSettings.toString()` and `SnodraMessagingProperties.toString()` print `****`, and with
`spring-boot-actuator` on the classpath the starter contributes a `SanitizingFunction` that masks it (and
`SNODRA_SERVER_TOKEN`) in `/actuator/configprops` and `/actuator/env` even with `show-values=ALWAYS` and whatever
sanitization the application configured. An empty token is no token (a `Register` without credentials, which `off` and
`permissive` hubs accept). **`token-file` wins when both are set** (it is the source that can rotate); the
file is read at startup, where a missing file fails the startup, and on every reconnect, so replacing the secret and
letting the connection reconnect (or fail once) is a rotation. **An empty file after a first good read** (a rotation that
replaces the file non-atomically can be caught half way) is treated like an unreadable one: the last token read is kept
and one `WARN` is logged, so a `Register` never goes out without its token just because of a race. At startup an empty
file still means no token. A file that disappears later likewise keeps the last token read and logs one warning.

**What the hub does with it**, and what you see:

| Hub (`enforce`) | Stream or request | In the client |
|---|---|---|
| no token, an empty token, an unknown token (a JWT on a hub with no issuer: "jwt credentials are not configured") | the hub closes the stream with `UNAUTHENTICATED` | registration rejection |
| `service-name` the token does not grant, or a handled type outside its `handle` | the hub closes the stream with `PERMISSION_DENIED` (naming the type) | registration rejection |
| a `Register` naming the instance id of a live session of **another service** (`enforce` and `permissive`; `off` keeps replacing it) | the hub closes the stream with `PERMISSION_DENIED` (`instance id … belongs to another service`); the owner's session is untouched | registration rejection |
| a request whose type is outside `send` (unary, scatter-gather, streaming, subscription) | an immediate `Error{PERMISSION_DENIED}`, nothing routed | `AccessDeniedException`, **never retried** |
| a request after the token left the ACL | an immediate `Error{UNAUTHENTICATED}` | `UnauthenticatedException`, never retried |

A **registration rejection** (`ALREADY_EXISTS`, `INVALID_ARGUMENT`, `UNAUTHENTICATED`, `PERMISSION_DENIED`, the last also for an instance id that belongs to another service): the status is
in `HubConnection.lastRejection`, `awaitRegistered` throws `HubRegistrationRejectedException` naming the code and the hub's
message, the connection reconnects at the backoff cap (80-100 % of `hub.reconnect-backoff.max`, no tight loop), logs at
`ERROR` once per distinct message and then at `DEBUG`, and keeps retrying (a fixed ACL or token file heals it without a
restart; `lastRejection` clears when a stream completes its handshake). The service keeps running; the hub counts every attempt as a
violation. In `permissive` nothing is refused: the hub logs and counts what `enforce` would refuse (except an instance-id
takeover, below, which it refuses too).

**Instance ids belong to a service.** A `Register` that names the instance id of a live session of *another* service is
refused with `PERMISSION_DENIED` (`instance id … belongs to another service`) in `enforce` and `permissive`, and the owner's
session is left alone, so a service with a valid token cannot hijack another one's stream and its queued requests. A
reconnect of the *same* service still replaces its own older stream. Make instance ids unique per instance (the default is
random) and never reuse another service's.

**The back-off is validated.** `hub.reconnect-backoff.max` must be positive and `min` positive and not above `max`; a bad
value fails the startup naming the property (a zero `max` would hot-loop handshakes against a refusing hub).

**TLS.** `hub.tls.enabled=true` with `hub.tls.ca-file` (the CA that signed the hub's certificate; the JVM's trust store when
absent) and, if the address is not a name on the certificate, `hub.tls.server-name`. It applies to every address form.
Plain text against a TLS hub (or TLS against a plain-text one) never hangs: the stream fails at once as
`UNAVAILABLE (io exception)` or `INTERNAL (http2 exception)` and the first `WARN` line that applies (not
necessarily the very first attempt: a hub that was still starting is a plain refusal, which carries no hint) says to check
`snodra.messaging.hub.tls.enabled` and `tls.ca-file`; later attempts log it at `DEBUG`. A client certificate (mTLS) is
[its own section](#authenticating-with-a-client-certificate-mtls); `DefaultHubChannelFactory.customizeTls` stays a hook for a subclass.

**Turning it on.** `enforce` last: (1) run the hub with `SNODRA_SERVER_AUTH_MODE=permissive` and an ACL file; (2) give every service its
token (and the CA, if the hub serves TLS); (3) watch `snodra_hub_auth_violations_total{reason,service}` and the dashboard until
it stays flat; (4) switch the hub to `enforce`; (5) turn on TLS before tokens cross an untrusted network. A service
whose token is missing or wrong in `enforce` fails visibly (`HubRegistrationRejectedException`, an `ERROR` line) instead of
reconnecting in a tight loop.

## Authenticating with a JWT (OAuth2 client credentials)

A service can present a short-lived OAuth2 access token instead of a static token. The hub validates it against the
realm's keys (`SNODRA_SERVER_JWT_ISSUER`, ...), requires
its `azp` to equal the service name and takes the rights from the `[[service]]` table of that name in its ACL file.

**The provider, in two lines.** One confidential client per service with *service accounts enabled and nothing else* (no standard
flow, no direct access grants), its **client id = the service name**; add an audience mapper and set the hub's
`SNODRA_SERVER_JWT_AUDIENCE`. Never give a `[[service]]` table to the user-facing client.

```yaml
snodra:
  messaging:
    hub:
      oauth2:
        token-uri: https://auth.example/realms/snodra/protocol/openid-connect/token
        client-secret-file: /run/secrets/snodra-client-secret   # client-id defaults to snodra.messaging.service-name
```

The environment forms are `SNODRA_SERVER_OAUTH2_TOKEN_URI`, `_CLIENT_ID`, `_CLIENT_SECRET`, `_CLIENT_SECRET_FILE`, `_SCOPE` and `_CA`
(relaxed binding also gives `SNODRA_MESSAGING_HUB_OAUTH2_*`); the properties win. A token URI together with a static `hub.token`
or `hub.token-file`, or without any secret, fails the startup. So does any `hub.oauth2.*` setting (or `SNODRA_SERVER_OAUTH2_*` variable)
without a token URI: a stray client id or secret would otherwise leave the service silently unauthenticated.

**How it behaves.**

- The `client_credentials` grant is a `POST` to the token URI (`application/x-www-form-urlencoded`, 10 s, answer capped at 1 MiB,
  redirects never followed), the client authenticated with HTTP Basic (id and secret form-urlencoded first, RFC 6749 2.3.1). The
  answer needs `access_token`; `expires_in` missing means 60 s (one `WARN`); a `token_type` other than `Bearer` is refused.
- **One token per process**, shared by every hub connection (N hubs, one fetch), fetched single-flight: connections that start
  together wait for the same request. Each new stream (connect, reconnect) gets a token before it sends `Register`.
- A cached token is used while more than its refresh margin is left; the provider **renews it in the background** at that
  point: margin = 20 % of the lifetime, at least 5 s, and at most half of it (a 6 s token is renewed after 3 s; the Rust library
  uses the same rule). A lifetime over 10 years (a huge `expires_in`) is cut to 10 years. The renewer looks at the wall clock at
  least every 5 s, so a clock that jumped ahead while the machine slept does not postpone the renewal. The renewal goes to every live
  stream (one that has its ack) as `ClientMessage.credentials`. The hub closes a JWT session at `exp` plus
  `SNODRA_SERVER_JWT_EXPIRY_GRACE` (30 s) without one.
- A renewal that fails keeps the current token and retries with a back-off from 1 s to 30 s (one `WARN` per distinct error).
- A stream the hub closes (or a `Register` it refuses) with `UNAUTHENTICATED` ("token expired", "unknown signing key",
  "credentials expired", a refused refresh) drops the cached token: the reconnect fetches a new one instead of presenting the
  same one until its margin runs out. `PERMISSION_DENIED` (wrong `azp`, no `[[service]]` entry) keeps it: a new token would not help
  and the identity provider is not asked again for every retry.
- **No token, no stream.** When the endpoint cannot give a token (401 `invalid_client`, down, TLS, an unusable answer) the stream is
  not opened: the attempt fails locally, `HubConnection.lastRejection` holds `UNAUTHENTICATED` and `awaitRegistered` throws
  `HubRegistrationRejectedException` ("no access token for ...: invalid_client: ..." with the endpoint's `error` and
  `error_description`, clipped to 200 characters), the connection retries with the normal reconnect back-off, logs `ERROR` once
  per distinct error and then `DEBUG`, and recovers by itself when the endpoint does. A hub that is not ready (`UNAVAILABLE`
  "jwks not loaded yet") is an ordinary reconnect.
- With a static `hub.token-file` the same message rotates the token without a reconnect: when the file's content changes the new
  token is sent as `ClientMessage.credentials` on every live stream (checked once per heartbeat).
- The client secret and the access tokens never appear in logs, exception messages, `toString()` or the actuator's `configprops`
  and `env` (the starter's `SanitizingFunction` masks `hub.oauth2.client-secret` and `SNODRA_SERVER_OAUTH2_CLIENT_SECRET`).

**What you can read.** `HubConnections.authStatus()` returns `kind` (`NONE`, `TOKEN`, `JWT`), the current token's `tokenExpiresAt`, the
`lastTokenError` (null once a fetch worked), `tokenFetches` by result and `credentialsRefreshesSent` (one process-wide counter: it never drops when a hub connection goes away): wire it into your own
health indicator. With Micrometer on the classpath the starter binds `snodra_messaging_hub_token_fetches_total{result}`
(`ok`, `http_error`, `oauth_error`, `io_error`, `bad_response`) and `snodra_messaging_hub_credentials_refreshes_sent_total`.

**Divergences from the Rust library** (same design, ecosystem differences): the Kotlin starter reports through
`HubConnections.authStatus()` and Micrometer counters where Rust has an accessor. A token URI host with an underscore in
its name is refused by the JDK's URI parser (the host would be null), so it fails the startup here; the Rust library accepts it.

## Authenticating with a client certificate (mTLS)

The hub can take a **client certificate** as the service's credential (issuing certificates and the hub's settings: `https://snodra.damoreira.com/concepts/security/`, "mTLS mode"). The TLS handshake
proves the service holds the key, the certificate names the service, and the rights are the hub's `[[service]]` table of that name, the
same table a JWT uses. No secret crosses the wire and no identity provider is involved.

```yaml
snodra:
  messaging:
    service-name: billing-service
    hub:
      tls:
        ca-file: /etc/snodra/hub-ca.pem                 # the CA that signed the hub's certificate (or the system roots)
        client-cert-file: /etc/snodra/tls/client.pem    # certificate chain, leaf first
        client-key-file: /etc/snodra/tls/client.key     # unencrypted PKCS#8 PEM
```

Environment names (relaxed binding): `SNODRA_MESSAGING_HUB_TLS_CLIENT_CERT_FILE`, `SNODRA_MESSAGING_HUB_TLS_CLIENT_KEY_FILE`.

- **Both files or neither.** One alone fails the startup naming the missing one. A client certificate **implies TLS**: `hub.tls.enabled`
  need not be set, and an explicit `hub.tls.enabled=false` next to the certificate settings fails the startup (the Rust library does the
  same with `SNODRA_SERVER_TLS_CLIENT_CERT`/`_KEY`).
- **One credential kind per service.** A client certificate together with a static token (`hub.token`, `hub.token-file`,
  `SNODRA_SERVER_TOKEN`, `SNODRA_SERVER_TOKEN_FILE`) or OAuth2 (`hub.oauth2.*`, `SNODRA_SERVER_OAUTH2_*`) fails the startup naming both: a stale
  token next to a good certificate would be refused by the hub. With a certificate the library sends no credentials at all.
- **The SAN rule.** The leaf must carry exactly one URI SAN `snodra://service/<name>` (the name is 1 to 128 characters of
  `[A-Za-z0-9._-]`; DNS, IP and other URI SANs are ignored; two such SANs, even equal ones, are refused as the hub refuses them), and
  `<name>` must be `snodra.messaging.service-name`. The hub would refuse anything else with `PERMISSION_DENIED` at `Register`; the
  starter says so at startup instead. Also checked at startup: both files exist, are not empty and parse, the key belongs to the
  certificate, and the certificate has not ended. The key must be **PKCS#8 PEM** (`-----BEGIN PRIVATE KEY-----`); RSA (`BEGIN RSA PRIVATE KEY`), SEC1 (`BEGIN EC PRIVATE KEY`)
  and encrypted keys are refused with the conversion hint (`openssl pkcs8 -topk8 -nocrypt`). The JDK reads RSA, EC and Ed25519 keys.
- **How to issue one.** Follow `https://snodra.damoreira.com/concepts/security/`, "mTLS mode" (`openssl`, or cert-manager with `uris:
  [snodra://service/billing-service]` and `usages: [client auth]`). Issue short-lived certificates (hours to days): there is no
  revocation list, so the lifetime is the revocation story.
- **Failures at the handshake are transport errors.** With `SNODRA_SERVER_TLS_CLIENT_AUTH=required`, no certificate or one the hub does not
  trust fails the TLS handshake, which TLS 1.3 shows when the stream opens: `UNAVAILABLE` ("ssl exception"), **not** a registration
  rejection. The library retries with its normal back-off and logs one `WARN` that names the fingerprint and what to check (the hub's
  `SNODRA_SERVER_TLS_CLIENT_CA`, the certificate's end, `hub.tls.ca-file`). A certificate that names no or several services, or another
  service than `service-name`, is `PERMISSION_DENIED` at `Register`: a rejection (`HubRegistrationRejectedException`). A client that presents **no** certificate to a hub that requires one gets the same transport
  failure; its `WARN` says that a hub which requires client certificates does that to a client that presents none, and to set
  `hub.tls.client-cert-file` and `client-key-file`.

**Rotation without a restart.** The files are read again on every (re)connect and once per check tick (3 s, the hub's heartbeat period).
A new connection attempt whose files cannot be used presents the last good certificate instead, with one `WARN` per problem. When the pair changed and is valid (the same checks as at startup, not expired, already valid), the instance first waits a **random delay**, uniform in
[0, min(30 s, 10 % of what is left of the certificate its streams present)] (none when that certificate has ended), so the replicas of a service
that read the renewed file within the same tick do not all deregister at once; the files are read again after the wait and the roll goes to the
pair that is current then. Then the hub connections **roll over to it
one hub at a time**: (1) the hub is told this instance is stopping (a `Register` with no types, as at shutdown), so it routes new work
to other instances; (2) the library waits up to 10 s for the work in flight on that stream (requests it sent and has no answer for,
requests it is handling; **not** the streams and subscriptions this instance itself consumes, see below); (3) the stream is closed gracefully (half-close, the hub's end awaited for 2 s); (4) it reconnects at once
(no back-off) with the new pair and waits up to 30 s for it to register again; only then the next hub is rolled, in target order. Write
the key first and the certificate second, or both with one rename each: a pair that does not match (a half-written replacement) is not
adopted and the current connection stays; the problem is logged at `DEBUG` when first seen and at `ERROR` (once) when the next check finds
it again, and the next check adopts the pair when it is complete.

- *Failed requests.* Requests accepted before the roll finish on the old stream. A sender that picks a hub in the middle of its roll gets
  `NO_HANDLER` from it when this instance was the only owner there, so a unary send **now fails over to another live hub that has a handler**
  (every hub answering `NO_HANDLER` returns the answer at once). A hub that has another live hub leaves this instance's own routing at once; the only hub leaves it after its work in flight finished.
- *One hub: a gap.* With a single hub there is nobody to take over: from the hub being told until the new stream is registered, the
  instance has no stream and takes no work. That is up to the drain (10 s at most, usually much less: only requests that are really in
  flight are waited for) plus the reconnect. Its own sends wait for the new stream within the call's deadline; requests other services send to
  it meanwhile get `NO_HANDLER` from the hub (give such a service two instances, or two hubs). The random delay above keeps the replicas of a
  service from all being in that gap at the same moment.
- *Streams and subscriptions.* A streaming handler counts as work in flight (it is waited for, up to 10 s, then cut like any lost stream).
  A subscription this instance serves does not hold the roll: it ends with the old stream (the hub tells the subscriber
  `HANDLER_DISCONNECTED`), as at any reconnect. **The same holds on the consumer side:** streams (`queryBus.stream`) and subscriptions
  (`queryBus.subscribe`) this instance itself consumes through the hub being rolled are not waited for either (they have no end of their own,
  so waiting would always cost the full 10 s); the roll cuts them, the stream or the `updates` flow fails with `HubConnectionLostException`,
  and the consumer subscribes again, as after any lost stream. A scatter-gather in flight, which ends within its deadline, is waited for.
- *Requests not yet written* when the stream closes follow the usual lost-stream rules (`HubUnavailableException`, sent again on another hub).
- A roll that does not complete (the new stream does not register within 30 s) stops the rollover for that pair with one `ERROR`: the other
  hubs keep the old pair until the files change again (the hub that did not register keeps trying with the new pair on its own).

**Expiry.** The hub closes a certificate session at `notAfter` with `UNAUTHENTICATED` "certificate expired" and no grace. A service whose
files are renewed before that never meets it. Otherwise: with less than a tenth of its lifetime (24 hours at most) left and no renewed
file, the library logs one `WARN` per certificate; when the hub closes the session at `notAfter` the library treats it as a normal
reconnect (it is **not** a registration rejection: no back-off at the cap) and reads the files again; if they still hold the expired
certificate, the attempt fails locally, without a handshake, as a registration rejection (`UNAUTHENTICATED` "client certificate ... expired
at ...": one `ERROR`, then retried at the back-off cap), and a renewed file is picked up by the next attempt.

**What you can read.** `HubConnections.authStatus()` has `kind = CERTIFICATE`, `certificateService`, `certificateFingerprint` (the first 8 hex characters of
the leaf's SHA-256, the only form of the certificate that is logged or shown; the hub's topology shows the same value), `certificateExpiresAt`
(`notAfter`) and `certificateRotations` (pairs adopted since start). With Micrometer the starter binds
`snodra_messaging_hub_certificate_rotations_total`. Logs name a certificate only by that fingerprint and the service; no key material
is ever logged, and `toString()` of the certificate objects shows neither key nor certificate.

**Divergences from the Rust library** (same design, ecosystem differences): the Kotlin starter reports through `authStatus()` and a
Micrometer counter where Rust has `hub_auth()`; the status fields are `certificate*` next to the existing `tokenExpiresAt`; the JDK's
PKIX validation rules apply to the hub's certificate (the Rust library uses rustls).

## Configuration keys

| Key | Default | Meaning |
|---|---|---|
| `snodra.messaging.service-name` | required | Logical name; Kafka consumer group; `Register.service_name` |
| `snodra.messaging.type-prefix` | required | Prefix for classes without `@MessageType` |
| `snodra.messaging.hub.enabled` | `true` | Set false to skip the hub connection (publish-only tools, unit tests) |
| `snodra.messaging.hub.address` | `static://snodra-server:7000` | The hub or hubs (plaintext gRPC): one target (`host:port`, `static://` optional), a comma-separated list (`static://hub:7000,hub-2:7000`; `static://` optional per entry, blanks and repeats dropped), or one `dns:///name:port` (port required, not combinable with other entries) whose addresses are re-resolved every 30 s. One connection per hub, see [Several hubs](api.md#several-hubs). A malformed value fails startup |
| `snodra.messaging.hub.status-interval` | `5s` | Period of the `InstanceStatus` report (connected hub ids, handlers in flight) to every live hub; also sent whenever the set of live hubs changes. Must be positive |
| `snodra.messaging.hub.request-timeout` | unset | Per-request timeout chosen by this service. Unset: the hub decides (`timeout_ms = 0`: its default, 5 s, or the type's override) and the client guards with the hub's bound for the type + 1 s. Set: sent as `timeout_ms` (the hub still clamps it, and its per-type override can then only shorten it), so leave it unset unless the service needs its own deadline; `0s` counts as unset |
| `snodra.messaging.hub.reconnect-backoff.min` | `500ms` | Exponential backoff floor when the stream drops; the backoff returns to it once an attempt reached the handshake |
| `snodra.messaging.hub.reconnect-backoff.max` | `5s` | Exponential backoff ceiling; every wait gets ±20 % jitter and never exceeds this (at the ceiling: 80-100 % of it) |
| `snodra.messaging.hub.max-concurrent-handlers` | `256` | Incoming requests handled at once by this instance over all hubs (at least 1, else startup fails); also sent as `Register.initial_permits` to every hub (split over N hubs, see [Several hubs](api.md#several-hubs)), which queues the excess. One permit goes back per completed handler: at once while the hub holds `min(16, max-concurrent-handlers / 2)` or fewer of them, else batched at 16 or after 50 ms |
| `snodra.messaging.hub.load-factor` | `100` | Relative capacity of this instance (`Register.load_factor`; 0 reads as 100, negative fails startup): weights its share of keyed commands (saturating at 800 on the ring) and its load score once instances are busy |
| `snodra.messaging.hub.tags.<name>` | none | `Register.tags`; unkeyed requests prefer instances whose tags match the sender's |
| `snodra.messaging.hub.priorities.<type>` | none (0) | Default `Request.priority` per message type; `SendOptions.priority` wins |
| `snodra.messaging.hub.max-subscriptions` | `1024` | Subscription queries this instance serves at once, over every hub (at least 1, else startup fails). The next one is refused with `ReplyEnd{RESOURCE_EXHAUSTED, "subscription limit (N) reached"}`, which the subscriber sees as a `HandlerBusyException`. A subscription holds no handler permit, so `max-concurrent-handlers` does not bound it; the default equals the hub's `SNODRA_SERVER_MAX_SUBSCRIPTIONS_PER_INSTANCE`. See [Subscription queries](api.md#subscription-queries) |
| `snodra.messaging.hub.token` | none | Static token sent in `Register.credentials.token` of every hub stream (hub access control, Hub token and TLS). An empty or blank value is no token. Never logged, redacted in `toString` and in the actuator's `configprops` and `env`. Environment: `SNODRA_MESSAGING_HUB_TOKEN`, or `SNODRA_SERVER_TOKEN` when the key is unset |
| `snodra.messaging.hub.token-file` | none | File holding the token (a container secret such as `/run/secrets/snodra-server-token`). Read at startup (an unreadable file fails it) and again on every reconnect; if a later read fails the last good token is kept. **Wins over `hub.token` when both are set.** Environment: `SNODRA_MESSAGING_HUB_TOKEN_FILE`, or `SNODRA_SERVER_TOKEN_FILE` when the key is unset |
| `snodra.messaging.hub.tls.enabled` | `false` | TLS to every hub of `hub.address` (every address form). The hub must serve TLS (`SNODRA_SERVER_TLS_CERT` / `SNODRA_SERVER_TLS_KEY`). Environment: `SNODRA_MESSAGING_HUB_TLS_ENABLED` |
| `snodra.messaging.hub.tls.ca-file` | JVM trust store | PEM file with the CA that signed the hub's certificate; read on every connection attempt. Set without `tls.enabled` it is ignored with a warning. Environment: `SNODRA_MESSAGING_HUB_TLS_CA_FILE` |
| `snodra.messaging.hub.tls.server-name` | the address's host | Name the hub's certificate must carry (and the SNI), for an address that is an IP or an alias the certificate does not list. Environment: `SNODRA_MESSAGING_HUB_TLS_SERVER_NAME` |
| `snodra.messaging.hub.retry.enabled` | `false` | Opt-in retry of the transient errors (see "Send options, priority and retry"); `SendOptions.retry` overrides per call. The `retry.*` values below are validated at startup even while this is `false` (attempts >= 1, multiplier >= 1, no negative backoff) |
| `snodra.messaging.hub.retry.max-attempts` | `3` | Total attempts, the first one included |
| `snodra.messaging.hub.retry.initial-backoff` | `100ms` | Wait before the second attempt |
| `snodra.messaging.hub.retry.multiplier` | `2` | Growth of the wait per further attempt |
| `snodra.messaging.hub.retry.max-backoff` | `2s` | Upper bound of a single wait |
| `snodra.messaging.kafka.bootstrap-servers` | `broker:19092` | Kafka |
| `snodra.messaging.kafka.topic` | `snodra.events` | Events topic |
| `snodra.messaging.kafka.consumer.enabled` | `true` | Set false in tools that only publish |
| `snodra.messaging.kafka.consumer.max-attempts` | `5` | Handler attempts per record before it is logged and skipped |
| `snodra.messaging.outbox.enabled` | `true` | Outbox collection + publisher |
| `snodra.messaging.outbox.poll-interval` | `200ms` | Publisher poll period |
| `snodra.messaging.outbox.batch-size` | `100` | Documents per poll |
| `snodra.messaging.outbox.retention` | `7d` | Delete sent documents older than this |
| `snodra.messaging.idempotency.retention` | `30d` | Delete `processed_events` older than this |
| `snodra.messaging.security.forward-jwt` | `true` | Put the current request's bearer token in `headers.authorization` |

The keys under `snodra.messaging.sagas.*`, `deadlines.*` and `external.*` are listed with their meaning in
[Sagas and deadlines](../index.md#saga-configuration).

Environment variable form follows Spring's relaxed binding, for example
`SNODRA_MESSAGING_HUB_ADDRESS`. Map keys taken from environment variables are lowercased with `_` read
as `.`, so `snodra.messaging.hub.priorities.<type>` cannot be set that way for a mixed-case type name
(`orders.CancelOrder`): put it in `application.yaml`, or in `SPRING_APPLICATION_JSON` when only the
environment is available.

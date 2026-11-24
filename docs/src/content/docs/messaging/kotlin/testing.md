---
title: "Testing"
---

## Test helpers (`snodra-messaging-test`)

- `InMemoryBuses(typePrefix, userId)`: implements `EventBus`, `CommandBus` and `QueryBus` in memory for unit tests without
  Docker. Messages still pass through the JSON codec. `register(handlerBean)` adds handlers; `published` lists events.
  A scatter-gather returns one part from the registered handler (service and instance `in-memory`); a streaming query
  collects the registered streaming handler's flow (honouring `maxResults`). A subscription query (`subscribe`) answers
  its initial result from the registered handler and takes its updates from `buses.emitter`, a local `QueryUpdateEmitter`
  (`emit`, `complete`, `completeExceptionally`, filtered like the real one; `buses.openSubscriptions` counts the open
  ones): no credits, and an emit is delivered at once, not after the commit of a surrounding transaction. `maxResults`,
  `cancel()` and `take(n)` end it as against a hub.
- `SnodraContainers.hubMtls(directory, services, serverCertificate, serverKey, clientCa, clientAuth = "required")`: the hub image
  (`SNODRA_SERVER_IMAGE`, default `snodra-server:dev`) in mode `enforce` with `[[service]]` tables and a client CA. Issue the hub's own
  pair from the client CA with both usages, so the image's health check (which presents it under `required`) passes. Generate the CA
  and the certificates at test time; the starter's own tests use BouncyCastle in test scope for that (the JDK's `keytool` cannot give a
  URI SAN and a seconds-long validity at once).
- `InProcessHub`: in-JVM stand-in for the hub (`start()`, `channel()`, `dropInstance(...)` (also with a `Status`), `lastRequestHeaders()`,
  `lastRequest()`, `registrationsFrom(...)`, `lastRegisterFrom(...)`, `acksSentTo(...)`, `echoHeartbeats = false` to
  simulate a hub that stopped answering), for hub-client tests without a container. It answers every
  `Register` with a `RegisterAck` (`heartbeatInterval`, `heartbeatTimeout`, `replyTimeout` as default, `maxTimeout`,
  `typeTimeouts`); `emitTimeouts = false` emulates a hub that loses requests. Flow control as the real hub: a first
  `Register` without permits is `INVALID_ARGUMENT`, permits, a per-instance queue by priority (`queueCapacity`, full:
  `RESOURCE_EXHAUSTED`), `permitsGrantedBy(...)`, `permitMessagesFrom(...)`, `permitsAvailable(...)`, `queuedFor(...)`,
  `forwardedOrder()`; permits never exceed the session's cap (`initial_permits`, raised by `Permits.grant`). Multi-hub: `lastStatusFrom(...)` (with the processors), `statusMessagesFrom(...)`,
  `requestsFrom(...)`, `sessionsOf(...)`,
  and `pauseReading = true` stops reading every stream. Like the real hub it keeps one session per instance id: a new
  stream registering an id replaces the older one (`sessionsReplacedOf(...)`, `streamsOpenedBy(...)`;
  `replaceSessions = false` keeps both), and `ackDelay` delays each `RegisterAck` as network latency would. Query modes:
  shared query types, scatter-gather with parts, end, `max_results`, the deadline and a `Cancel` to every forwarded
  target of a gather that ends early, as the real hub; an unknown request mode is `INVALID_REQUEST`, and `inject(instanceId,
  message)` writes any server message to an instance's stream. Streaming queries: one target, credits
  (`uint32`) and `Flow`, parts and ends relayed, `max_results`, the idle timeout (paused while the credit is 0),
  `maxStreamDuration`, cancels both ways and the gates as the real hub (a unary `Reply` to the target is ignored),
  `dropParts` drops relayed parts by `seq` (the real hub's full-buffer drop), and `openStreams()`,
  `creditOf(requestId)`, `flowsFrom(instanceId)` and `cancelsFrom(instanceId)` observe it. Subscription queries:
  every live instance of the type is a target as they are at the open, the initial request goes out as `<id>#0` through a
  permit and the queue, updates are renumbered behind the initial part under the sender's credit and the buffer
  (`subscriptionBuffer`, 256: one more ends it), `max_results` counts updates, cancels fan out both ways, a target leaving is
  silent unless it was the last (`HANDLER_DISCONNECTED`), `maxSubscriptionsPerInstance` (1024) refuses with
  `RESOURCE_EXHAUSTED`, `maxSubscriptionDuration` (off) ends with `CANCELLED`, and the gates are the real hub's,
  `Register.subscription_query_types` included (the subset check, registrants agreeing, and `INVALID_REQUEST` for a
  point query, stream or gather of a subscription type and for a subscription of an undeclared type);
  `openSubscriptions()`, `subscriptionTargetsOf(instanceId)`,
  `subscriptionCreditOf(requestId)` and `bufferedUpdatesOf(requestId)` observe it. Processor control:
  `control(instanceId, request)` sends a `ControlRequest` to the instance's session and awaits its `ControlReply` from that
  session, `controlRepliesFrom(instanceId)` lists every reply.
- `InProcessHub.auth`: `HubAuth.enforce(tokens)`, `HubAuth.permissive(tokens)` or `HubAuth.OFF` (default), with `tokens` a
  map from the plain test token to `AclEntry(service, handle, send)` (patterns: exact, `prefix.*`, `*`), answers like the real
  hub: in `enforce` the first `Register` is closed with `UNAUTHENTICATED` (no credentials, an empty token, a `jwt` on a hub
  without `services`, an unknown token) or `PERMISSION_DENIED` (another service name, a command, query or shared query outside `handle`), a later `Register`
  adding a forbidden type likewise, and a request outside `send` gets an immediate `Error{PERMISSION_DENIED}` in every
  request mode (`UNAUTHENTICATED` if the token left `auth` meanwhile). `prefix.*` needs something after the dot (it does not
  match `prefix.` itself). `auth` may be replaced at runtime and, like the real hub on an ACL reload, replacing it in `enforce`
  closes the live sessions the new ACL no longer allows (`UNAUTHENTICATED` for a token that left, `PERMISSION_DENIED` for a
  service name or handled type it no longer grants; their in-flight requests fail as on any disconnect); set
  `closeSessionsOnAuthChange = false` to keep them and test the per-request refusal instead. Like the real hub (unless `auth` is `OFF`), a `Register` naming the instance id of a live session of another service is closed with `PERMISSION_DENIED` (`instance id … belongs to another service`) and the owner is left alone. `permissive` allows and records. `authViolations()` lists every violation (code, message, enforced, a monotonic timestamp, so tests can assert
  the spacing of reconnects) and `tokensSeenFrom(instanceId)` the token of every `Register` received, refused ones included.
- `InProcessHub` and JWT credentials: `HubAuth.enforce(tokens, services)` / `permissive(tokens, services)` take the `[[service]]`
  tables as `AclEntry(service, handle, send)`. A `jwt` credential whose `azp` is the registering service and that has such an
  entry is accepted with its rights; another `azp` or a service without an entry is `PERMISSION_DENIED`, a token that is not three
  segments with an `azp` is `UNAUTHENTICATED`, and without `services` the hub answers "jwt credentials are not configured". The
  signature and `exp` are **not** checked (use the real hub image for that). `jwtsSeenFrom(instanceId)` lists the JWTs of the
  `Register`s and `credentialsSeenFrom(instanceId)` the `jwt` or `token` of every `ClientMessage.credentials`, and a refresh is judged
  like a `Register`'s against the session's own service. `SnodraContainers.hubJwt(...)` starts the hub image under test with JWT
  authentication (issuer, JWKS URI, `[[service]]` ACL file, leeway 0 s, expiry grace 2 s).
- `TestCertificates.generate(dir, names)`: a throwaway self-signed certificate made at test time with the JDK's `keytool`
  (PEM certificate, also the CA a client trusts, and PKCS#8 key; valid for `localhost` and `127.0.0.1` by default).
- `SnodraContainers`: unstarted Testcontainers definitions. `kafka()`, `mongo()` (single-node replica set, needed for
  transactions), `hub()` from the hub image under test, `snodra-server:dev` or the one named by `SNODRA_SERVER_IMAGE`, with ports 7000 and 7001
  (every hub test runs on it: the hub and this library ship together), `hub(env)` for it with extra `SNODRA_SERVER_*`
  settings, `hubAcl(dir, acl, authMode, tls, env)` for it with access control and TLS (it writes the ACL file, with the
  SHA-256 of each token, into `dir` and copies it and the `TestCertificates` into the container, with
  `SNODRA_SERVER_AUTH_MODE`, `SNODRA_SERVER_ACL_FILE`, `SNODRA_SERVER_TLS_CERT` and `SNODRA_SERVER_TLS_KEY` set), `hubJwt(...)` and
  `hubMtls(...)` (below), and `hubImageAvailable()`.
- `SnodraTestKafka(bootstrap, typePrefix, topic).awaitEvent<T>()`: reads an event back from the topic.
- `SagaTestFixture(SagaClass::class, beans…)`: drives one saga with events and time, in memory; see [Testing a saga](/docs/messaging/kotlin/api/#testing-a-saga).

```kotlin
val buses = InMemoryBuses(typePrefix = "workouts")
buses.register(WorkoutHandlers(repo, buses))   // the handler publishes events through the same in-memory bus
val result = buses.sendBlocking(LogWorkout("legs"))
```

The end-to-end test (`TwoServicesEndToEndTest`) starts Kafka, MongoDB, the real hub and two Spring Boot services. It is
skipped when `snodra-server:dev` (or the image named by `SNODRA_SERVER_IMAGE`) is not present in the local Docker daemon. Build the image from the snodra-server repo:

```bash
docker build -t snodra-server:dev .
```

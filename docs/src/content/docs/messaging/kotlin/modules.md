---
title: "Modules, build and examples"
---

## Modules

| Module | Coordinates | Purpose |
|---|---|---|
| `snodra-messaging-api` | `com.damoreira.snodra:snodra-messaging-api` | `@MessageType`, `Event`, `Command<R>`, `Query<R>`, `StreamingQuery<R>`. No Spring. Depended on by every `*-api` module. |
| `snodra-messaging` | `com.damoreira.snodra:snodra-messaging` | Spring Boot starter: buses, handler annotations, hub client, outbox, Kafka consumer, sagas, deadlines and the external-integration toolkit, auto-configuration. |
| `snodra-messaging-test` | `com.damoreira.snodra:snodra-messaging-test` | `InMemoryBuses`, `InProcessHub`, `SnodraContainers`, `SnodraTestKafka`, `SagaTestFixture`. |
| `examples/examples-api`, `examples/service-a`, `examples/service-b` | not published | Two sample services talking through the hub; see [Examples](#examples). |

## Requirements

- JDK 25 (Temurin), found on the PATH or by the Gradle toolchain resolver.
- Docker for the container tests (Kafka, MongoDB, and the hub image for the end-to-end test).

Rancher Desktop: Testcontainers needs two environment variables, otherwise it does not find the Docker socket.

```bash
export DOCKER_HOST=unix://$HOME/.rd/docker.sock
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
```

or the equivalent lines in `~/.testcontainers.properties`:

```properties
docker.host=unix:///Users/<you>/.rd/docker.sock
testcontainers.docker.socket.override=/var/run/docker.sock
```

## Build, test, publish

```bash
./gradlew build                  # compile + all tests (needs Docker, see above)
./gradlew publishToMavenLocal    # installs the modules into ~/.m2, to try a local change in a service
```

Releases are cut by CI, never by hand: on a push to `main`, the Conventional Commit subjects since the last `vX.Y.Z`
tag decide the next version (`feat` a minor, `fix` or `perf` a patch, anything else no release). CI builds and checks
the bundle with that version, tags the tested commit, and publishes every module to Maven Central (signed, with sources
and javadoc) and its JARs to the GitHub release. The version comes from the tag (`-Pversion`); no file holds it, so a
local build without `-Pversion` is not a release.

The published POM and Gradle module metadata carry resolved versions for every dependency (Gradle `versionMapping`), and the
POM also imports the Spring Boot BOM, so consumers do not need to manage them.

## Examples

`examples/` holds two tiny Spring Boot services built on this starter: service-a sends a command and a query over
the hub and reacts to an event, service-b owns the command and the query and publishes the event. They run in
Docker Compose from local builds together with the real `snodra-server` image, Kafka and MongoDB, and are driven with
`curl`. service-b also runs a saga against a fake partner (the postcard printer) over all three inbound channels; see
[Sagas](/docs/messaging/kotlin/api/#sagas) and `examples/README.md`.

## CI/CD pipeline

Two GitHub Actions workflows. `.github/workflows/ci.yml` runs on every push and pull request:

| Job | Runs | Does |
|---|---|---|
| `build` | always | `./gradlew assemble` |
| `proto-sync` | always | checks that `hub.proto` equals the server's |
| `test` | always | `./gradlew test`, with the hub image the end-to-end tests need |
| `throughput` | after `test` | `./gradlew throughputTest` |
| `scripts` | always | the tests of the release scripts |
| `version` | a push to `main` of `snodra/snodra-messaging`, once every job above passed | the next version from the Conventional Commit subjects since the last `vX.Y.Z` tag; none means no release |
| `package` | when there is a version | builds the Maven Central bundle with it and checks it |
| `tag` | after `package` | tags the tested commit `vX.Y.Z` |
| `release` | after `tag` | calls `.github/workflows/release.yml` with the tag |

`.github/workflows/release.yml` checks the tag, creates the GitHub release, publishes every module to Maven Central
(signed, with sources and javadoc; a version already there is not uploaded again) and attaches the JARs to the release.
It can also be run by hand to publish an existing tag again; nobody pushes tags.

Consumers resolve the artifacts from Maven Central (`mavenCentral()`), as `com.damoreira.snodra:snodra-messaging` and
the other modules' coordinates at a released version. No Docker image is built: this is a library; the example services
are built from source by their Docker Compose file.

## Known limitations

- Hub authentication is a static token per service, a OAuth2 client-credentials JWT or a client certificate (mTLS).
  A static token is a long-lived secret: rotate it through `hub.token-file`. An access token that the provider revokes keeps working until
  it expires (minutes); a certificate until its `notAfter` or until the hub's `[[service]]` table is removed (no CRL, no OCSP: issue
  short-lived certificates). A client key must be unencrypted PKCS#8 PEM. With a single hub, a certificate rotation leaves the instance
  without a stream for a moment (see the rotation notes above).
- Event processors: attempts and back-off are shared by all processors; one consumer thread per processor and instance.
- No leader election for the outbox publisher; with several instances delivery is at-least-once and ordering is per
  publishing instance.
- A stream pins one handler instance for its whole life: a restart of that instance fails the stream
  (`HANDLER_DISCONNECTED`), and the library never resumes it. A subscription's update targets are fixed when it opens
  (at-most-once updates): an instance that starts later is never added and the library never resubscribes, so a
  subscriber that must hear every instance resubscribes itself (opt-in auto-resubscribe is future work).
- Library metrics are limited to the JWT credential counters and the saga toolkit's (see [Sagas](/docs/messaging/kotlin/api/#sagas)), both Micrometer and optional; there are no metrics for the buses, the outbox or the consumer yet. OpenTelemetry comes from the application.
- Configuration metadata is hand-maintained in `META-INF/spring-configuration-metadata.json`.
- `TraceHeaders` is only active with Micrometer Tracing on the classpath.
- Trace context is injected on outbound messages (hub requests, outbox events) but not yet extracted on inbound hub
  requests or Kafka records, so a handler's spans do not join the caller's trace.
- No service-to-service identity yet: commands sent from event handlers, sagas or scheduled jobs carry no token, so they can
  only reach handlers without `@RequiresAuthentication` (a `snodra-system` client-credentials token is future work).
- Sagas: a new saga type does not see events from before its deployment (no replay);
  parked saga events are retried by a person through `SagaFailures`; a saga belongs to one service.
- Sagas, reviewed and left as they are: `saga_dispatch` entries that failed for good and `saga_failures` documents have no TTL; a
  `startKey` is `"<type>|<key>=<value>"`, so an association key that contains `=` can make two pairs share one live instance
  (avoid `=` in keys); the smoke test does not check that a restart replays nothing twice (the tests do).

<p align="center">
  <img alt="Snodra mascot" src="assets/brand/svg/snodra.svg" width="160">
</p>

# Snodra

One messaging stack for services that speak Kafka and gRPC — without a commercial messaging platform.

Snodra gives a service commands, queries, events and sagas. Commands and queries go through
**Snodra Server**, a stateless gRPC router. Events go to the event store you already run — Kafka or
RabbitMQ Streams — through a transactional outbox, with the message store of your choice (MongoDB,
PostgreSQL or MySQL) holding the outbox, the processed markers and the saga state. One protocol,
first-class Kotlin and Rust libraries.

You run the server, point your services at it, and stop maintaining a service registry, deadline
handling and a control plane of your own.

## Map of the documentation

<div class="grid cards" markdown>

-   :material-rocket-launch:{ .lg .middle } **[Getting started](getting-started/index.md)**

    ---

    Install the server, add a client library, and send a first command.

-   :material-lightbulb-on-outline:{ .lg .middle } **[Core concepts](concepts/index.md)**

    ---

    CQRS, commands, queries, events, sagas and the guarantees behind them.

-   :material-book-open-variant:{ .lg .middle } **[Reference](reference/index.md)**

    ---

    The server, the Kotlin library, the Rust library and the wire contract.

-   :material-puzzle-outline:{ .lg .middle } **[Add-ons](add-ons/index.md)**

    ---

    Event stores and message stores: Kafka, RabbitMQ Streams, MongoDB and SQL.

-   :material-server-network:{ .lg .middle } **[Operations](operations/index.md)**

    ---

    Monitoring, testing, tuning and upgrades for a running deployment.

-   :material-connection:{ .lg .middle } **[Integrations](integrations/index.md)**

    ---

    Spring Boot, Keycloak, OpenTelemetry, containers and existing services.

-   :material-tools:{ .lg .middle } **[Tools](tools/index.md)**

    ---

    The event browser and the conformance runner.

-   :material-swap-horizontal:{ .lg .middle } **[Migration](migration/index.md)**

    ---

    Moving from `kraken`, and what the protocol version guarantees.

-   :material-file-document-multiple-outline:{ .lg .middle } **[Examples and editions](examples/index.md)**

    ---

    Runnable starting points, the licence and the editions of Snodra.

</div>

## Where to go first

| You are… | Start with | Then |
|---|---|---|
| new to CQRS and event-driven services | [CQRS](concepts/cqrs.md) | [Commands](concepts/commands.md), [Queries](concepts/queries.md) and [Events](concepts/events.md) |
| adopting Snodra in an existing system | [Installation](getting-started/installation.md) | [Your first service](getting-started/first-service.md) and [Spring Boot](integrations/spring-boot.md) |
| operating Snodra | [Operations](operations/index.md) | [Monitoring](operations/monitoring.md), [Tuning](operations/tuning.md) and [Upgrades](operations/upgrades.md) |

## Try the server

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT= \
  snodra/snodra-server:0.5.0
```

The gRPC listener is on `7000`; the dashboard and its API are on <http://localhost:7001/ui/>. An
empty topology is correct: the server learns ownership from the connections. [Installation](getting-started/installation.md)
covers the client libraries, and [the quick start](server/quickstart.md) takes the server from there.

## What it is not

A message broker, an event store, a durable queue, or a workflow engine. The server routes commands
and queries to a live handler and relays the answer; events go to your event store and state lives
in your database. [Core concepts](concepts/index.md) explains what each part owns.

## Licence

[Apache-2.0](concepts/license.md). See [Editions](editions.md) for what is open source and what is
sold separately.

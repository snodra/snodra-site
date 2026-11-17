<p align="center">
  <img alt="Snodra mascot" src="assets/brand/svg/snodra.svg" width="160">
</p>

# Snodra

One messaging stack for services that speak Kafka and gRPC — without a commercial messaging platform.

[`snodra-server`](https://github.com/snodra/snodra-server) is a stateless gRPC router for synchronous
commands and queries. Events never pass through it: they go straight to Kafka, through a transactional outbox. You run
the server, point your services at it, and stop maintaining a service registry, deadline handling and a control plane of
your own.

- **No Axon Server, no event store.** The server keeps no state; kill it and clients reconnect and re-register.
- **Horizontal by design.** Run several servers; clients connect to all of them, with no server-to-server traffic.
- **Control plane included.** Pause, resume, reset and replay event processors, and work dead letters, from the
  dashboard or the HTTP API.
- **See what happens.** Topology, queue depth, processor lag, and an event browser that reads the event store.
- **One protocol, two clients.** A single `.proto` with first-class Kotlin and Rust libraries.
- **Four auth modes.** Anonymous, static token, Keycloak JWT or mTLS, with a permissive-first rollout.

## Start the server

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT= \
  snodra/snodra-server:latest
```

Open the dashboard at <http://localhost:7001/ui/>. That is a server with no services registered yet; [the quick
start](server/quickstart.md) takes it from there.

## Where to go

| If you want to… | Read |
|---|---|
| run the server and connect a first service | [Server quick start](server/quickstart.md) |
| understand the protocol | [Protocol](server/protocol.md) · [Routing](server/routing.md) |
| build a Kotlin service | [Kotlin](messaging/kotlin/quickstart.md) |
| build a Rust service | [Rust](messaging/rust/quickstart.md) |
| see a complete setup | [Examples](examples/index.md) |
| know what is free and what is not | [Editions](editions.md) |

## What it is not

A message broker, an event store, a durable queue, or a workflow engine. Kafka carries events and MongoDB (or another
message store) carries state; the server only routes commands and queries to a live handler and relays the answer.

## Licence

[Apache-2.0](concepts/license.md).

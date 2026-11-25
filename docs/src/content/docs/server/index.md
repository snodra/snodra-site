---
title: "Snodra Server"
---

A stateless gRPC router for synchronous commands and queries between services. Services open one
bidirectional stream, register the command and query types they handle, and the hub forwards each
request to a live instance and relays the reply. Events never pass through the hub; they go
straight to Kafka.

## Why run it

- **No external event store.** The hub keeps only an in-memory registry. Kill it and
  clients reconnect and re-register; there is nothing to back up.
- **No per-service plumbing.** Registration, health, request deadlines, retries and flow control
  live in the hub and in one client library, not in every service.
- **Horizontal by design.** Run several hubs; each client connects to all of them. No hub-to-hub
  traffic, no leader.
- **The control plane is included.** Pause, resume, reset and replay event processors, and retry or
  discard dead letters, from the dashboard or the HTTP API.
- **You can see what is happening.** Topology, per-instance queue depth, processor status, consumer
  lag and an event browser are part of the binary.
- **One protocol, four clients.** One `.proto`, a Kotlin Spring Boot starter, a Rust crate, a Go
  module and a Python package (commands and queries only); anything that speaks gRPC can talk to it.

## What it is not

A message broker, an event store, a durable queue, or a workflow engine. Kafka carries events and
MongoDB carries state; the hub only routes commands and queries to a live handler and relays the
answer.

## Run it

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT= \
  snodra/snodra-server:latest
```

The dashboard is at [http://localhost:7001/ui/](http://localhost:7001/ui/). [The quick start](/docs/server/quickstart/) checks health and
sends a first request; [server settings](/docs/server/configuration/server/) lists every environment variable.

## How a request travels

1. Every service instance opens `Hub.Connect` and sends `Register` with its service name, instance
   id and the command, query and shared query types it handles.
2. The hub records the types and answers `RegisterAck` with its id, heartbeat period and limits.
3. A sender sends `Request` with a type; the hub picks a live instance that handles it, applies
   flow control and forwards it.
4. The handler answers `Reply` (or parts, for streaming); the hub relays them to the sender and
   enforces the deadline.

The full contract is in [the protocol page](https://snodra.damoreira.com/docs/server/protocol/).

## Licence

Apache-2.0. See [the licence](/docs/concepts/license/).

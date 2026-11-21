# Reference

The complete contract behind the concepts: the server, the messaging model and the two client
libraries. Use these pages when you need an exact setting, method or wire rule.

## The server

[Snodra Server](../server/index.md) routes commands and queries between live service instances. The
section covers the quick start, authentication, every server setting, topology, the dashboard,
processor control, the event browser, routing, the protocol, the lifecycle, operations, observability,
the image and the known limitations.

Start with [the quick start](../server/quickstart.md) or [server settings](../server/configuration/server.md).

## The messaging model

[The messaging model](../messaging/index.md) is the shared specification of the Kotlin and Rust
libraries: message naming, the wire types, query modes, the outbox, the Kafka layout, dead letters,
sagas, event processors and the hub protocol.

## The Kotlin library

[snodra-messaging](../messaging/kotlin/index.md) is the Spring Boot starter. Its pages cover the quick
start, configuration, the API, testing and the modules and build.

## The Rust library

[snodra-messaging-rs](../messaging/rust/index.md) is the Rust crate. Its pages cover the quick start,
configuration, the API, dead letters, sagas, testing and the modules and build.

## The stores

The event store and message store are add-ons with their own reference pages:
[Add-ons](../add-ons/index.md). The installation coordinates for every artifact are in
[Installation](../getting-started/installation.md).

## For library authors

[Writing a library](../library-authors/index.md) is the specification for a client library in another language: the hub
protocol, the messages, the feature levels, the store add-ons and the conformance runner that proves a library.

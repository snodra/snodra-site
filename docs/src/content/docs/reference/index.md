---
title: "Reference"
---

The complete contract behind the concepts: the server, the messaging model and the client
libraries. Use these pages when you need an exact setting, method or wire rule.

## The server

[Snodra Server](/docs/server/) routes commands and queries between live service instances. The
section covers the quick start, authentication, every server setting, topology, the dashboard,
processor control, the event browser, routing, the protocol, the lifecycle, operations, observability,
the image and the known limitations.

Start with [the quick start](/docs/server/quickstart/) or [server settings](/docs/server/configuration/server/).

## The messaging model

[The messaging model](/docs/messaging/) is the shared specification of the Kotlin and Rust
libraries: message naming, the wire types, query modes, the outbox, the Kafka layout, dead letters,
sagas, event processors and the hub protocol.

## The Kotlin library

[snodra-messaging](/docs/messaging/kotlin/) is the Spring Boot starter. Its pages cover the quick
start, configuration, the API, testing and the modules and build.

## The Rust library

[snodra-messaging](/docs/messaging/rust/) is the Rust crate. Its pages cover the quick start,
configuration, the API, dead letters, sagas, testing and the modules and build.

## The Go library

[snodra-messaging-go](/docs/messaging/go/) is the Go library, pre-1.0 and at feature level 1 (commands and
queries; no events, sagas or add-ons yet). Its pages cover the quick start, configuration, the API and testing.

## The Python library

[snodra-messaging-python](/docs/messaging/python/) is the Python library, pre-1.0 and at feature level 1 (commands and
queries; no events, sagas or add-ons yet). Its pages cover the quick start, configuration, the API and testing.

## The stores

The event store and message store are add-ons with their own reference pages:
[Add-ons](/docs/add-ons/). The installation coordinates for every artifact are in
[Installation](/docs/getting-started/installation/).

## For library authors

[Writing a library](/docs/library-authors/) is the specification for a client library in another language: the hub
protocol, the messages, the feature levels, the store add-ons and the conformance runner that proves a library.

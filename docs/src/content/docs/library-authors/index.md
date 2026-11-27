---
title: "Writing a library"
---

This section is for anyone who chooses a Snodra library or writes one for a language Snodra does not cover
yet. After reading this page you know what a library does, which libraries exist and how far each goes, and how a
community library gets listed here. The pages after it describe everything a library does on the wire, so a library can
be written from them alone.

## What a library does

A Snodra library is what a service links to take part in Snodra. It:

- connects the service to every hub of the deployment over one `Hub.Connect` stream per hub, registers the command and
  query types the service handles, and keeps the stream alive;
- sends commands and queries through the hub (point queries, scatter-gather, streaming and subscription queries) and
  answers the ones routed to the service, under the hub's flow control;
- carries the acting user's token, the correlation id and the trace context from one message to the next;
- publishes events through a transactional outbox in the service's own database to an event store, and handles events
  at least once with duplicates skipped (with a message-store add-on and an event-store add-on);
- runs named event processors that report their status to the hub and answer its controls (pause, resume, reset and
  replay, dead letters);
- runs sagas and deadlines.

What a library must do for each is graded in four [feature levels](/docs/library-authors/feature-levels/): **1 Core** (commands, queries,
every query mode, credentials, several hubs), **2 Events**, **3 Processors**, **4 Sagas**.

## Official libraries

| Library | Language | Licence | Feature level | Conformance |
|---|---|---|---|---|
| [snodra-messaging](/docs/messaging/kotlin/) ([releases](https://github.com/snodra/snodra-messaging/releases)) | Kotlin (Spring Boot starter) | Apache-2.0 | 4, implemented; level 1 proved by the runner | level 1 passes every check of the runner through `examples/conformance-service`; the event-store and message-store kits pass |
| [snodra-messaging](/docs/messaging/rust/) ([releases](https://github.com/snodra/snodra-messaging-rs/releases)) | Rust | Apache-2.0 | 4, implemented; level 1 proved by the runner | level 1 passes every check of the runner through the runner's own reference service; the event-store and message-store kits pass |
| [snodra-messaging-go](/docs/messaging/go/) ([releases](https://github.com/snodra/snodra-messaging-go/releases)) | Go | Apache-2.0 | 3, implemented; level 1 proved by the runner, levels 2 and 3 by the add-on kits and the library's own tests | level 1 passes every check of the runner through `examples/conformance-service`; the level-2 and level-3 event-store and message-store kits pass (the event-store kit omits the four `browse`-capability checks: no event browser) |
| [snodra-messaging-python](/docs/messaging/python/) ([PyPI](https://pypi.org/project/snodra-messaging/)) | Python | Apache-2.0 | 3, implemented; level 1 proved by the runner, levels 2 and 3 by the add-on kits and the library's own tests | level 1 passes every check of the runner through `examples/conformance-service`; the level-2 and level-3 event-store and message-store kits pass |

The Kotlin and Rust libraries are reference implementations of the same contract: a service on one is indistinguishable
from a service on the other in front of the hub and the event store. The Go and Python libraries are pre-1.0 and
implement level 3: commands and queries through the hub, events through the outbox and the event stores, and named
processors with their status, control, leased reset and replay and dead letters. They have no sagas or external calls
(level 4) and no event browser yet. The
[conformance runner](/docs/library-authors/conformance/) ([releases](https://github.com/snodra/snodra-conformance/releases)) proves level 1
for all four; levels 2 to 4 are proved by the add-on kits and, for the rules the runner does not check yet, each
library's own tests.

### Interoperability

The Kotlin and Rust libraries were run against each other on shared infrastructure (2026-11-15, one hub, Kafka 4.4.0,
RabbitMQ Streams 4.4.0, PostgreSQL 17.7, MySQL 8.4.7, MongoDB 8.3.13): events published by one were read by the other
with identical key, headers, payload and id on both event stores, with the same partitions and routing; a Kotlin and a
Rust instance shared one Kafka consumer group and one RabbitMQ Streams consumer name, handing partitions over at the
stored offsets; dead letters of either were read by both; on PostgreSQL and MySQL each library checked the other's
schema and relayed, marked, claimed and read the other's outbox entries, markers, sagas, deadlines, dead letters and
processor control; on MongoDB the same, after the fixes for optional fields; and a chain of commands and events
through one hub crossed the languages eight times with the same `traceparent` and correlation id. Not run: saga
runtimes continuing a saga started in the other language, two languages as instances of one service through their
real cores, and the Kotlin RabbitMQ Streams add-on on a cluster ([event-store-add-ons.md](/docs/library-authors/event-store-add-ons/#rabbitmq-streams-wire-rules)
has the cluster run of the Rust add-on).

## Community libraries

| Library | Language | Licence | Feature level | Conformance version |
|---|---|---|---|---|

None yet. Yours could be the first.

## Add your library

A library is listed here when it has:

- **a public repository**, with a README that says how to install and configure it;
- **an OSI-approved licence**;
- **a passing conformance report** for the feature level it claims, from the [conformance runner](/docs/library-authors/conformance/),
  naming the runner's version. For levels 2 to 4, which the runner does not check yet, list the
  [feature-level checks](/docs/library-authors/feature-levels/) your library's own tests cover, and the add-on kits it passes.

To ask for the listing, open a pull request to [snodra-site](https://github.com/snodra/snodra-site) that adds a row
for your library to the [Community libraries](#community-libraries) table, with the runner's text report attached.

The suggested name is `snodra-messaging-<language>` (`snodra-messaging-go`, `snodra-messaging-python`, ...).

## The pages of this section

| Page | For |
|---|---|
| [writing-a-library.md](/docs/library-authors/writing-a-library/) | the build order, the state machines, the pitfalls the official libraries met, what levels 2 to 4 add (the saga dispatch, retries and failure notice) |
| [protocol.md](/docs/library-authors/protocol/) | the `Hub.Connect` stream: registering, heartbeats, reconnects, credentials, requests and errors, timeouts, flow control, the query modes, several hubs, status and processor control |
| [messages.md](/docs/library-authors/messages/) | type names, JSON payloads, the event headers, correlation id, trace context, forwarded identity, handler errors |
| [feature-levels.md](/docs/library-authors/feature-levels/) | the four levels and the check ids that prove each |
| [event-store-add-ons.md](/docs/library-authors/event-store-add-ons/) | writing an event-store add-on, its conformance kit, the RabbitMQ Streams wire rules, the event browser's queries |
| [message-store-add-ons.md](/docs/library-authors/message-store-add-ons/) | writing a message-store add-on, its conformance kit, the SQL layout |
| [mongodb-layout.md](/docs/library-authors/mongodb-layout/) | the MongoDB layout of a message store: collections, document fields and BSON types, indexes, the atomic operations, and where the two official add-ons differ |
| [conformance.md](/docs/library-authors/conformance/) | what proves each level, the conformance runner (level 1) and its report |
| [Kotlin](/docs/messaging/kotlin/), [Rust](/docs/messaging/rust/), [Go](/docs/messaging/go/), [Python](/docs/messaging/python/) | the official libraries: install, configure, modules (in the reference section of this site) |

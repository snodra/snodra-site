---
title: "snodra-messaging-python"
---

The official Python client library of the Snodra messaging suite. An asyncio service registers handlers for commands,
queries, streaming queries and subscription queries, and sends messages to other services, through a Snodra hub: the
library keeps the hub streams, permits, retries and timeouts, and you write async functions.

```sh
pip install snodra-messaging
```

**Status: pre-1.0, feature level 1.** The library implements level 1 of the protocol and passes all 33 checks of the
[conformance runner](/docs/tools/conformance-runner/) through `examples/conformance-service`. The versions are on
[PyPI](https://pypi.org/project/snodra-messaging/); all are pre-1.0, so the API may still change between minor versions.
It needs Python 3.12 or later.

## What it gives you

- Typed handlers: `@app.command_handler`, `@app.query_handler`, `@app.stream_handler` and `app.subscription_handler`,
  with guards (`authenticated()`, `role()`, `caller_matches()`).
- Sending: `send` and `query`, with per-call timeout, routing key, priority, headers and an opt-in retry policy.
- Every query mode: point, scatter-gather (`gather`), streaming (`stream`) and subscription (`subscribe`); streams and
  subscriptions are async context managers and iterables (`async with`, `async for`).
- The hub connection: registration, heartbeats, reconnect with backoff, flow control, timeouts, several hubs and an
  ordered shutdown.
- Static token, OAuth2 JWT (client credentials) and mutual TLS credentials, with rotation.
- Caller identity from the forwarded token, verified against the issuer's keys (`JWKS`); guards need a JWKS.
- Commands and queries of the service's own types answered in-process, without the hub, unless
  `always_route_through_hub` is on.
- Telemetry behind an interface, with an OpenTelemetry implementation in the separate `snodra-messaging-observability`
  package and the metric names and labels of the Kotlin, Rust and Go libraries.

## Level 1 only

The Python library is at [feature level 1](/docs/library-authors/feature-levels/): commands and queries through the hub.
The features of levels 2 to 4 are not in it yet: no events, no event store or message store add-ons, no outbox, no event
processors, no dead letters and no sagas. For those, use the [Kotlin](/docs/messaging/kotlin/) or [Rust](/docs/messaging/rust/)
library.

## Pages

- [Quick start](/docs/messaging/python/quickstart/): a service in one file.
- [Configuration](/docs/messaging/python/configuration/): the `SNODRA_*` variables, the `Settings` field that sets each, and every hub credential.
- [API](/docs/messaging/python/api/): handlers, sending, the four query modes, errors, identity, lifecycle and telemetry.
- [Testing](/docs/messaging/python/testing/): testing handlers, and running the conformance runner against the library's own service.

The library's source, its `SPEC-GAPS.md` (where each specification rule the library had to decide comes from; the
library follows the Kotlin library) and its releases are in the
[repository](https://github.com/snodra/snodra-messaging-python).

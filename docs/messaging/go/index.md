# snodra-messaging-go

The official Go client library of the Snodra messaging suite. A service registers handlers for commands, queries,
streaming queries and subscription queries, and sends messages to other services, through a Snodra hub: the library
keeps the hub streams, permits, retries and timeouts, and you write functions.

```sh
go get github.com/snodra/snodra-messaging-go
```

**Status: pre-1.0, feature level 1.** The library implements level 1 of the protocol and passes all 33 checks of the
[conformance runner](../../tools/conformance-runner.md) through `examples/conformance-service`. No version has been
released yet and the API may still change before 1.0. It needs Go 1.26 or later.

## What it gives you

- Typed handlers: `HandleCommand`, `HandleQuery`, `HandleStream` and `HandleSubscription`, with guards
  (`RequireAuthenticated`, `RequireRole`, `RequireCaller`).
- Sending: `Send` and `Query`, with per-call timeout, routing key, priority, headers and an opt-in retry policy.
- Every query mode: point, scatter-gather (`Gather`), streaming (`Stream`) and subscription (`Subscribe`); streams and
  subscription updates are `iter.Seq2[T, error]`.
- The hub connection: registration, heartbeats, reconnect with backoff, flow control, timeouts, several hubs and an
  ordered shutdown.
- Static token, OAuth2 JWT (client credentials) and mutual TLS credentials, with rotation.
- Caller identity from the forwarded token, verified against the issuer's keys (`JWKS`); guards need a JWKS.
- Commands and queries of the service's own types answered in-process, without the hub, unless
  `AlwaysRouteThroughHub` is on.
- Telemetry behind an interface, with an OpenTelemetry implementation in the separate `observability` module and the
  metric names and labels of the Kotlin and Rust libraries.

## Level 1 only

The Go library is at [feature level 1](../../library-authors/feature-levels.md): commands and queries through the hub.
The features of levels 2 to 4 are not in it yet: no events, no event store or message store add-ons, no outbox, no event
processors, no dead letters and no sagas. For those, use the [Kotlin](../kotlin/index.md) or [Rust](../rust/index.md)
library.

## Pages

- [Quick start](quickstart.md): a service in one file.
- [Configuration](configuration.md): the `SNODRA_*` variables, the option that sets each, and every hub credential.
- [API](api.md): handlers, sending, the four query modes, errors, identity, lifecycle and telemetry.
- [Testing](testing.md): testing handlers, and running the conformance runner against the library's own service.

The library's source, its `SPEC-GAPS.md` (the places where the specification was silent: what the libraries do, and
what is settled as the specification; the library follows the Kotlin library) and its releases are in the
[repository](https://github.com/snodra/snodra-messaging-go).

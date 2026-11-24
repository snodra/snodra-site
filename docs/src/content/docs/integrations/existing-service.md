---
title: "Integrating an existing service"
---

A service does not need a Snodra library to join the system. The server speaks plain gRPC over the
`snodra.hub.v1` package, and a client in any language can open the stream, register its types and
answer requests. This page is the integration checklist; the exact messages are in
[Protocol](/docs/server/protocol/).

## What the service must implement

1. **Connect.** Open `Hub.Connect`, a bidirectional stream, once per instance.
2. **Register.** Send `Register` first, with `service_name`, `instance_id`, the `commands` and
   `queries` (and `shared_queries`) it handles, `initial_permits` and optionally `credentials`.
   Wait for `RegisterAck` before relying on routing.
3. **Serve.** Read `ServerMessage.request`, decode the payload, run the handler and send
   `ClientMessage.reply` with the same `request_id`. A handler error goes in `Reply.error`, not in a
   dropped stream.
4. **Heartbeat.** Send `Heartbeat` on the interval from the ack and echo the server's heartbeats.
5. **Flow control.** Grant permits as handlers complete; do not expect more concurrent requests than
   the permits you offered.
6. **Reconnect.** On a stream end, reconnect with backoff and register again. Requests in flight when
   the stream breaks have an unknown outcome.

## The contract you share

- **Type names are global.** The wire name (`orders.PlaceOrder`) is the routing key and must match the
  owner's `*-api` module or documented contract. A typo creates a second, unrelated type.
- **Payloads are opaque bytes to the server.** They are JSON documents in the Snodra libraries; agree
  on the JSON shape with the other services. The server never decodes or logs them.
- **One terminal message per request id.** A `Reply` or an `Error`, never both. For multi-part modes,
  `ReplyPart`s and one `ReplyEnd`.
- **Deadlines are the server's.** It applies the request's `timeout_ms`, the type override or the
  default, and answers `TIMEOUT` when it passes.
- **Credentials.** A static token, a JWT or a client certificate can authenticate the stream; the
  ACL then decides which types the service may handle and send.

## What you can skip

Events, the outbox, sagas, processors and testing kits are library features, not protocol
requirements. A service that only serves commands and queries needs the hub client alone. A service
that publishes events needs an event store and a message store, or it can call the owning service.

## Verifying it

The [conformance runner](/docs/tools/conformance-runner/) checks a client library against the
contract, including the handshake, flow control, failover and credentials. For a one-off integration,
start with a single hub, no authentication and one command type, then add TLS and access control; see
[the quick start](/docs/server/quickstart/) and [Lifecycle](/docs/server/lifecycle/).

# The hub protocol

This page is for anyone writing a Snodra library, in any language, or debugging one: it describes the
`Hub.Connect` stream from the client's side, message by message, with what the hub does in answer and what a library
must do in turn. After reading it you can connect to every hub of a deployment, register handlers, send and answer
commands and queries in every mode, keep within flow control, authenticate, and report status and answer processor
controls. The hub's own view of the same stream is the [server's protocol summary](../server/protocol.md), and its
registry, routing, queues, settings and dashboard are in the [server reference](../server/index.md); the payloads and
headers are in [messages.md](messages.md).

<!--
Protocol names in inline code spans and in text blocks follow the marking convention of
scripts/check-library-spec.sh (described in its header); `make docs-check` checks every one against hub.proto.
-->

**The source of truth** is [`proto/hub.proto`](https://github.com/snodra/snodra-server/blob/main/proto/hub.proto) in
`snodra-server`, package `snodra.hub.v1`; both official libraries vendor a byte-identical copy of it. This page quotes
it and never restates it differently; where they seem to differ, hub.proto wins and this page has a bug. The hub and
the libraries ship together and there is one version of everything until v1: no negotiation, no capability flags, no
compatibility layer. A library generates its bindings from hub.proto with the language's gRPC tooling.

Words used below: a **sender** is the instance that sends a `Request`; a **handler** is the instance a `Request` is
forwarded to; a **session** is one `Hub.Connect` stream as the hub sees it. "Must" marks a rule a library has to
follow; each names the conformance check that proves it (`L1-HANDSHAKE-ACK` and so on, listed in
[feature-levels.md](feature-levels.md)).

## The service

```proto
service Hub {
  rpc Connect(stream ClientMessage) returns (stream ServerMessage);
  rpc Topology(TopologyRequest) returns (TopologyResponse);
}
```

- `Hub.Connect` is the one long-lived stream per service instance and hub. Everything on this page travels on it.
- `Hub.Topology` is a point-in-time snapshot for operators and tooling (never payloads or headers). A library does not
  need it. In access-control mode `enforce`, or when the hub has a dashboard token, it needs a credential
  ([Topology](../server/topology.md)).

What travels on the stream:

| `ClientMessage` (instance to hub) | `ServerMessage` (hub to instance) |
|---|---|
| `ClientMessage.register`: `Register`, first message and later re-registrations | `ServerMessage.register_ack`: `RegisterAck`, one per accepted `Register` |
| `ClientMessage.heartbeat`: `Heartbeat` | `ServerMessage.heartbeat`: the echo |
| `ClientMessage.request`: a `Request` this instance sends | `ServerMessage.request`: a `Request` for one of this instance's handlers |
| `ClientMessage.reply`: the `Reply` to a forwarded request | `ServerMessage.reply`: the `Reply` to a request this instance sent |
| | `ServerMessage.error`: an `Error` the hub produced for a request this instance sent |
| `ClientMessage.part`, `ClientMessage.end`: a handler's `ReplyPart` and `ReplyEnd` (streaming, subscription) | `ServerMessage.part`, `ServerMessage.end`: the answers of a multi-part request this instance sent |
| `ClientMessage.flow`: a sender's credits (`Flow`) | `ServerMessage.flow`: a sender's credits, passed to a streaming handler |
| `ClientMessage.cancel`: a sender cancels (`Cancel`) | `ServerMessage.cancel`: the hub cancels a request this instance handles |
| `ClientMessage.permits`: `Permits` (flow control) | |
| `ClientMessage.status`: `InstanceStatus`, every 5 s | |
| `ClientMessage.credentials`: a refreshed `Credentials` | |
| `ClientMessage.control_reply`: `ControlReply` | `ServerMessage.control`: `ControlRequest` (processor control) |

## Connect and register

```text
client                                   hub
  Register{..., client_version,      -->   registers the instance
           initial_permits}
  Heartbeat{sent_at_ms=t}            -->
                                     <--   RegisterAck{hub_id, heartbeat_interval_ms,
                                                       heartbeat_timeout_ms, default_timeout_ms,
                                                       max_timeout_ms, context, type_timeouts_ms}
                                     <--   Heartbeat{sent_at_ms=t}   (echo)
```

**The first message.** A library must open every stream with a `Register`, followed by a `Heartbeat`
(`L1-REGISTER-FIRST`). A first message that is not a `Register` closes the stream with the gRPC status
`FAILED_PRECONDITION`; a stream without a `Register` within the hub's handshake deadline (10 s,
`SNODRA_SERVER_HANDSHAKE_TIMEOUT`) is closed with `DEADLINE_EXCEEDED`.

**What a `Register` says** (hub.proto is the reference for each field):

| Field | Rule |
|---|---|
| `Register.service_name` | the logical service name, not empty; each event-store add-on derives its own names from it |
| `Register.instance_id` | unique per process (a UUID generated at startup, or a pod name), not empty; the hub keeps one session per instance id |
| `Register.command_types`, `Register.query_types` | fully qualified type names ([messages.md, Type names](messages.md#type-names)); a type in both is `INVALID_ARGUMENT` |
| `Register.shared_query_types` | query types many services may own ([Shared query types](#shared-query-types)) |
| `Register.initial_permits` | at least 1 (0 is `INVALID_ARGUMENT`): the requests the hub may forward before the next `Permits`, and the session's permit cap ([Flow control](#flow-control)) |
| `Register.load_factor` | relative capacity, 0 reads as 100 |
| `Register.tags` | free labels; unkeyed requests prefer instances whose tags match more of the sender's |
| `Register.credentials` | a token or a JWT when the hub's access control is on ([Credentials](#credentials)) |
| `Register.client_version` | free text; a library should send `<library>/<version>`, as the Rust library sends `snodra-messaging-rs/` followed by its crate version; shown in the topology, never used for routing |

**The ack.** Every accepted `Register` is answered with a `RegisterAck`, written before the echo of any `Heartbeat`
that follows it (the hub handles a stream's messages in order). The ack is the confirmation that the `Register` was
processed. A library must count a stream as registered only once its `RegisterAck` arrived, and must close and reopen
a stream that has no ack within its own handshake timeout (10 s in both official libraries); a heartbeat echo alone
confirms nothing (`L1-HANDSHAKE-ACK`). The ack carries what the client aligns with:

| `RegisterAck` field | Use |
|---|---|
| `RegisterAck.hub_id` | identifies this hub process; the key for [several hubs](#several-hubs) |
| `RegisterAck.heartbeat_interval_ms` | the heartbeat period ([Heartbeats](#heartbeats-and-the-dead-peer-timeout)) |
| `RegisterAck.heartbeat_timeout_ms` | the hub evicts the session after this long without a `Heartbeat` |
| `RegisterAck.default_timeout_ms`, `RegisterAck.max_timeout_ms`, `RegisterAck.type_timeouts_ms` | the request timeout rules ([Timeouts](#timeouts)) |
| `RegisterAck.context` | always `default` until contexts ship |

**Requests may arrive before the ack.** The hub may route requests to a new instance as soon as its `Register` is
processed, so a `ServerMessage.request` can come before the `RegisterAck`. A library must serve such requests and count
them against its permits like any other (`L1-EARLY-REQUESTS`).

**Refusals.** A `Register` the hub refuses closes the stream with a gRPC status instead of an ack:

| Status | Why |
|---|---|
| `INVALID_ARGUMENT` | an empty `Register.service_name` or `Register.instance_id`, the service name `snodra-server` or an instance id starting with `snodra-server/` (reserved for the hub's own requests), `Register.initial_permits` 0, a type listed as both command and query, a type listed as shared and as a command or exclusive query in one `Register` |
| `ALREADY_EXISTS` | a type another service owns (exclusive types have one owner), a type whose kind differs from the kind its current owner registered, a type registered exclusive by one registrant and shared by another |
| `UNAUTHENTICATED`, `PERMISSION_DENIED` | the hub's access control ([Credentials](#credentials); the cases are in [Connection lifecycle, Failure modes](../server/lifecycle.md#failure-modes)) |

A refusal is a deployment problem, not a crash: a library must keep the service running, keep retrying at its backoff
cap (no tight loop: after a refused `Register` it waits at least 1 s, and at most its backoff cap of at most 5 s,
before the next attempt to that hub) and expose the reason (the official libraries log it once per distinct message and keep it as the
connection's last rejection) (`L1-REJECTION`). A stream the hub closes with `UNAVAILABLE` (for example "jwks not
loaded yet") is an ordinary closure: reconnect from the backoff floor.

**Later `Register`s.** A later `Register` on the same stream replaces the instance's type lists (handlers added after
startup) and is acked too, but the ack of a later `Register` is dropped, like a heartbeat echo, when the session's
outbound buffer is full: a library must not wait on it (`L1-HANDSHAKE-ACK`). `Register.credentials`, `Register.initial_permits`, `Register.load_factor`,
`Register.tags` and `Register.client_version` are read from the first `Register` of a stream only. A `Register` with
no types takes the instance out of the routing: an instance stopping gracefully, or leaving one hub, can send one, and
the hub routes what it had queued for the instance to the other instances at once.

**A reused instance id.** A new stream that registers the same `Register.instance_id` replaces the previous session;
requests forwarded to the old stream fail at once with `ErrorCode.HANDLER_DISCONNECTED`. With access control on, an
instance id held by a live session of another service is refused with `PERMISSION_DENIED`.

## Heartbeats and the dead-peer timeout

- A library must send a `Heartbeat` every `RegisterAck.heartbeat_interval_ms` (3 s by default; before the ack, the
  official libraries use 3 s) (`L1-HEARTBEAT`). `Heartbeat.sent_at_ms` is the sender's wall clock, for skew
  diagnostics only. The hub echoes a client `Heartbeat` with `Heartbeat.sent_at_ms` unchanged.
- The hub evicts a session after `RegisterAck.heartbeat_timeout_ms` (10 s by default) without a heartbeat, and at once
  when the stream closes; requests forwarded to an evicted instance fail with `ErrorCode.HANDLER_DISCONNECTED`.
- A library must drop a stream that brought no echo for three heartbeat intervals and reconnect (`L1-SILENT-HUB`).
  The official libraries also send HTTP/2 keepalive pings every 10 s, answered within 5 s, also while idle, so a
  one-way partition is noticed by the transport too.

## Reconnect and backoff

When a stream fails or the hub closes it, a library must reconnect and send the same `Register` again, with a backoff
whose cap is at most 5 s, and never stall (`L1-RECONNECT`). The official libraries wait 500 ms, doubling up to 5 s,
each wait jittered by ±20 % and never above the maximum, and go back to 500 ms once an attempt reached the handshake
(the ack); a registration refusal waits 80 to 100 % of the maximum.
What happens to the requests in flight on the lost stream is in
[Never sent or outcome unknown](#never-sent-or-outcome-unknown).

## Shutting down

A library should leave the hubs in this order (none of it is a must, and no check covers it); the empty `Register`
comes first, and the order between ending the served subscriptions and draining the handlers is free:

1. send a `Register` with no types to every hub: the hub takes the instance out of the routing and routes what it had
   queued for it to the other instances at once;
2. end the subscriptions it serves with a `ReplyEnd`, and let the handlers in flight finish (bounded), in either order;
3. half-close each stream and wait (bounded) for the hub to finish its side, so nothing still on its way is lost.

Both official libraries do all three, and both wait at most 1 s for the acks of the empty `Register` before they go
on. The Kotlin library ends its subscriptions before it waits for its handlers, so subscribers hear at once; the Rust
library waits for its handlers first, then ends its subscriptions and closes its streams.

## Credentials

The hub's side, its modes (`off`, `permissive`, `enforce`) and the ACL file are in
[Authentication](../server/configuration/index.md).

When the hub's access control is on, a service authenticates in one of three ways (the official libraries refuse a
configuration that combines them):

- **A static token** in `Register.credentials.token` on every stream to every hub (the hub reads it from the first
  `Register` of a stream). A library must never log it (`L1-TOKEN`).
- **A JWT** in `Register.credentials.jwt`: a client-credentials access token whose `azp` claim is the service name. A
  library must renew it before it expires (both official libraries renew at 80 % of its lifetime) and send each new
  token on the live streams as `ClientMessage.credentials`, at most one per renewal: the hub looks at most at one
  refresh per second per session and drops the rest without a reply. There is no reply on success. After a stream the
  hub closed with `UNAUTHENTICATED`, the next stream must register with a newly fetched token; after
  `PERMISSION_DENIED` a new token would not help (`L1-JWT`). In mode `enforce` the hub closes a JWT session that got
  no successful refresh by the token's `exp` plus its expiry grace (30 s by default, `SNODRA_SERVER_JWT_EXPIRY_GRACE`)
  with `UNAUTHENTICATED` "credentials expired". A hub that has no JWT issuer configured refuses a JWT with
  `UNAUTHENTICATED`.
- **A client certificate** (mutual TLS): no field in hub.proto, the certificate comes from the connection. It must carry
  exactly one URI SAN `snodra://service/<name>` naming the service of `Register.service_name`. The hub closes the
  session at the certificate's `notAfter` with `UNAUTHENTICATED` "certificate expired", with no grace, so a library must
  reload the certificate files and reconnect with the renewed pair before then; that close is an ordinary reconnect at
  the normal backoff, not a registration refusal (`L1-MTLS`). A `ClientMessage.credentials` on a certificate session is
  ignored.

**TLS.** A hub with TLS on accepts TLS only; plain text to it fails the handshake. A library must offer TLS with a CA
of the operator's choice and the server name to verify (`L1-TLS`).

**Requests the access control refuses.** A request for a type the service's ACL entry does not let it send is answered
before routing with `Error{PERMISSION_DENIED}`, in every request mode; a request after the service's credential left
the ACL with `Error{UNAUTHENTICATED}`. Neither is ever worth a retry.

## Requests

A `Request` carries:

| Field | Rule |
|---|---|
| `Request.id` | unique, chosen by the sender (a UUID); replies, parts, ends and errors carry it back |
| `Request.kind` | `RequestKind.COMMAND` or `RequestKind.QUERY`; `RequestKind.REQUEST_KIND_UNSPECIFIED` is `INVALID_REQUEST` |
| `Request.type` | the fully qualified type name |
| `Request.routing_key` | optional; commands with the same key for the same type go to the same instance of the owning service (consistent hashing), typically the aggregate id; ignored for queries |
| `Request.payload` | a JSON document, UTF-8 ([messages.md](messages.md#payloads)) |
| `Request.headers` | transport metadata ([messages.md, Request headers](messages.md#request-headers)) |
| `Request.timeout_ms` | a timeout hint ([Timeouts](#timeouts)) |
| `Request.mode` | `RequestMode.UNARY` (the default) or a multi-part mode ([Query modes](#query-modes)) |
| `Request.priority` | higher first when the hub queues requests for an instance; 0 by default |
| `Request.initial_credit`, `Request.max_results` | for the multi-part modes |

A request without a kind, a type or an id is answered `Error{INVALID_REQUEST}` "invalid request: ...". The hub
forwards a request to the handler without changes (for the multi-part modes, under a derived id).

### Request ids

A library must give every send attempt a fresh `Request.id` and never reuse an id while a request with it is pending
(`L1-REQUEST-ID`): a request whose id (or a derived `<id>#<n>`) is already in flight is refused with
`Error{INVALID_REQUEST}` "invalid request: duplicate id", and the earlier request is untouched. The identifier a
handler uses to detect a retried command is the aggregate or command id inside the payload, never `Request.id`.

### Timeouts

The hub emits `ErrorCode.TIMEOUT` when no answer arrives in time. The effective timeout, with *override* the hub's
per-type override for `Request.type` (`RegisterAck.type_timeouts_ms`):

| `Request.timeout_ms` | Deadline |
|---|---|
| `> 0` | `min(timeout_ms, override or max_timeout_ms)` |
| `0` | `override or default_timeout_ms` (5000 ms unless configured) |

A library must send `Request.timeout_ms` = 0 unless its caller chose a timeout, so the hub's per-type overrides apply
without client configuration, and must give up locally only after the hub's bound for the request plus 1 s, so the
hub's `ErrorCode.TIMEOUT` normally arrives first (`L1-TIMEOUT`). The bound is the hub's deadline when the library can
know it, and an upper bound of it otherwise: with a caller's timeout (`Request.timeout_ms` > 0), `min(timeout_ms,
override or max_timeout_ms)` from the table above; with 0, the override, else `RegisterAck.max_timeout_ms` (the hub
applies the override or `RegisterAck.default_timeout_ms`, which is never above the maximum). A
queued request keeps its own deadline.

### Replies and errors

The answer to a unary request is exactly one of:

- `ServerMessage.reply`: the handler's `Reply`, with `Reply.payload` (a JSON document; `{}` for a command without a
  result) or `Reply.error` (the handler's `Error`, forwarded as is);
- `ServerMessage.error`: an `Error` the hub produced.

`Error.message` is human readable, safe to log and to show a developer, never meant for end users; `Error.details`
holds optional machine-readable details from the handler (empty for hub-generated errors). A library must surface each
code as its own error, and keep `Error.message` for the codes a handler produces (`ErrorCode.HANDLER_ERROR`,
`ErrorCode.UNAUTHENTICATED`, `ErrorCode.PERMISSION_DENIED`, `ErrorCode.INVALID_REQUEST`) and `Error.details` for
`ErrorCode.HANDLER_ERROR` (`L1-ERRORS`). A code it does not know reads as `ErrorCode.HANDLER_ERROR`, and so does
`ErrorCode.ERROR_CODE_UNSPECIFIED`, which nobody sends on purpose:

| `ErrorCode` | Produced by | Meaning for the sender | Retry |
|---|---|---|---|
| `ErrorCode.NO_HANDLER` | hub; a handler that does not serve the type | no live instance registered the type (or the instance reached no longer handles it) | the handler never ran: safe, later |
| `ErrorCode.TIMEOUT` | hub; the sender's local guard | no answer in time: the handler may or may not have run | queries yes; commands only if idempotent |
| `ErrorCode.HANDLER_DISCONNECTED` | hub | the handler's stream closed before it answered: outcome unknown | as `ErrorCode.TIMEOUT` |
| `ErrorCode.HANDLER_ERROR` | handler | the handler failed; `Error.message` and `Error.details` say how | the application decides |
| `ErrorCode.UNAUTHENTICATED` | handler; hub (access control) | no readable caller identity, or the forwarded JWT failed validation; at the hub, a credential that left the ACL | no |
| `ErrorCode.PERMISSION_DENIED` | handler; hub (access control) | the caller lacks the right the handler requires; at the hub, a type outside the ACL entry's `send` | no |
| `ErrorCode.INVALID_REQUEST` | hub; handler | malformed or duplicate request, unknown mode, a part without credit (hub); a payload that does not decode, or the wrong mode for the handler (handler) | no: a contract mismatch |
| `ErrorCode.RESOURCE_EXHAUSTED` | hub; a handler's subscription limit | the target cannot take the request now (its queue or session buffer is full); the handler never saw it | yes, with backoff |
| `ErrorCode.CANCELLED` | hub | a stream or subscription outlived the hub's maximum duration | no: open a new one |

How the hub decides each case (queues, grace periods, reconnects) is in
[Connection lifecycle, Failure modes](../server/lifecycle.md#failure-modes). Nothing is retried by the hub: retries
are the sender's.

### Never sent or outcome unknown

A library must tell a caller apart whether a failed request was **never sent** or has an **unknown outcome**
(`L1-NEVER-SENT`):

- **Never sent**: no handshaken stream, or the request was never handed to the transport (it still sat in the
  library's own outbound buffer when the stream broke). The handler never saw it: a retry is safe, even for a command.
- **Outcome unknown**: the request was handed to the transport and the stream broke before the answer. It may be on
  the wire, handled or not. Treat it like `ErrorCode.TIMEOUT`.

**Retries are opt-in.** When a library retries (both official libraries offer an opt-in policy), it must retry a
command only when the handler never ran (never sent, `ErrorCode.NO_HANDLER`, `ErrorCode.RESOURCE_EXHAUSTED`) and never
after an unknown outcome, `ErrorCode.TIMEOUT` or `ErrorCode.HANDLER_DISCONNECTED`; a query may also be retried after
those. Each attempt gets a fresh `Request.id`, all attempts share the caller's time budget, and each attempt sends what
is left of it as `Request.timeout_ms`, never 0 (0 would let the hub apply its default) (`L1-RETRY`).

### Handling a request

When a `ServerMessage.request` arrives, a library must:

- **Answer on the stream it arrived on** (`L1-ARRIVAL-STREAM`), never on whatever stream is current: the hub accepts
  a reply, a part or an end only from the session the request was forwarded to. When that stream is gone, the answer is
  dropped: the hub has already failed the request with `ErrorCode.HANDLER_DISCONNECTED`.
- **Send exactly one terminal message per request id** (`L1-ONE-TERMINAL`): one `Reply` for a unary request, one
  `ReplyEnd` for a streaming request or a subscription target, and nothing at all after a `ServerMessage.cancel` for
  that id. Every answer carries the id it was forwarded with, exactly: `Reply.request_id`, `ReplyPart.request_id` and
  `ReplyEnd.request_id` are the forwarded `Request.id`, which is the sender's id for a point query or a command,
  `<id>#<n>` for a scatter-gather target, `<id>#1` for a streaming request, `<id>#0` for a subscription's initial
  request and `<id>#<n>` for a subscription target.
- **Turn every outcome into a message, never into a dropped stream** (`L1-HANDLER-ERRORS`): a type this instance does
  not serve is `ErrorCode.NO_HANDLER`; a payload that does not decode, or a request in the wrong mode for the handler
  (a unary request to a streaming handler, for example), is `ErrorCode.INVALID_REQUEST`; the caller's identity
  failures are `ErrorCode.UNAUTHENTICATED` and `ErrorCode.PERMISSION_DENIED`; anything else the handler raises,
  including a failure of a call the handler made itself (its own `ErrorCode.NO_HANDLER`, say), is
  `ErrorCode.HANDLER_ERROR` with a short message and never a stack trace. A failure the library cannot catch
  (a crash of the handler's task) is `ErrorCode.HANDLER_ERROR` too.
- **Check the caller before decoding the payload** when the handler requires an authenticated caller
  ([messages.md, Forwarded identity](messages.md#forwarded-identity)) (`L1-IDENTITY`).
- **Give the permit back** once the request is finished, whatever the outcome ([Flow control](#flow-control)).

## Flow control

- Every session is flow-controlled. `Register.initial_permits` are its first permits: the hub forwards a request only
  while the session holds a permit (one per forward) and queues the rest per instance, by `Request.priority` (higher
  first), then arrival, each with its own deadline. `Permits.count` adds permits, never beyond the session's cap, which
  starts at `Register.initial_permits`.
- A library must offer its local capacity (the handlers it runs at once) as `Register.initial_permits` and give one
  permit back for every finished request, on the stream the request arrived on (`L1-PERMITS`). It sends the pending
  grants in one `Permits` message at once when the hub holds `min(16, initial_permits / 2)` or fewer of its permits
  (with one permit: every completion), and otherwise batched, at 16 pending grants or 50 ms after the first unsent
  one. The hub still holds `initial - received + returned` permits for a stream: offered, minus requests that arrived,
  plus permits written back. Without the immediate return, a one-permit instance would be paced at about 20 requests
  per second by the batching timer.
- `Permits.grant` raises the session's cap to `max(cap, grant)` before `Permits.count` is added; a grant never lowers
  the cap. Only a library connected to [several hubs](#several-hubs) needs it.
- A subscription target takes no permit; a streaming handler holds its permit until the stream ends.
- When a handler's queue at the hub is full (10 000 requests or 64 MiB per instance, 512 MiB over the hub, by default)
  or its session buffer is full, the sender gets `Error{RESOURCE_EXHAUSTED}`; the handler never saw the request.

Routing among an owner's instances (consistent hashing for keyed commands; tag match, then free capacity, then least
loaded, then round-robin for the rest; `Register.load_factor` weighting) is the hub's:
[Routing and ownership, Routing rules](../server/routing.md#routing-rules).

## Query modes

`Request.mode` says how the hub
delivers a request and its answers: `RequestMode.UNARY` (0, the default), `RequestMode.SCATTER_GATHER`,
`RequestMode.STREAMING` and `RequestMode.SUBSCRIPTION`. The modes other than `RequestMode.UNARY` are for queries only:
a command fails with `ErrorCode.INVALID_REQUEST`, and so does a mode value hub.proto does not define. Every session may
use every mode.

### Shared query types

- `Register.query_types`: exclusive, one owning service.
- `Register.shared_query_types`: many services may own the type, each with its own instances. Registrants must agree on
  exclusive or shared (`ALREADY_EXISTS` for the later one); commands are never shared.
- A **point query** (`RequestMode.UNARY`) on a shared type goes to one live instance of any owner.
- A library must let a handler register a query type as shared and answer point queries on it like any query
  (`L1-SHARED`).

### Scatter-gather

A sender sends a query `Request` with `Request.mode` = `RequestMode.SCATTER_GATHER`:

```text
sender                         hub                                targets (every live instance of every owner)
  Request{id=g,            -->    Request{id=g#0, mode=UNARY}  -->  a1 (service A)
          mode=SCATTER_GATHER}
                                 Request{id=g#1, mode=UNARY}  -->  b1 (service B)
                                 Request{id=g#2, mode=UNARY}  -->  b2 (service B)
                          <--    ReplyPart{g, seq 0, B/b2, payload}     <-- Reply g#2
                          <--    ReplyPart{g, seq 1, A/a1, error}       <-- Reply{error} g#0
                          <--    ReplyPart{g, seq 2, B/b1, payload}     <-- Reply g#1
                          <--    ReplyEnd{g, parts 3, failed 1, timed_out 0}
```

- **Targets:** every live instance of every owner (on an exclusive type, every live instance of its owner). Only
  instances whose `Register` listed the type are targets, unlike a point query: during a rolling deploy that adds a
  type, the old instances (which would answer `ErrorCode.NO_HANDLER`) are left out. An instance registered without
  types is no target.
- **Each target gets an ordinary unary request** with id `<id>#<n>` and the sender's payload, headers, priority and
  routing key, served like any request. Flow control, queues, priority and session buffers apply per target as for any
  request. Handlers need nothing new.
- **Each answer becomes a `ReplyPart`** (in arrival order, `ReplyPart.seq` 0, 1, 2, ...): `ReplyPart.request_id` is
  the sender's id, `ReplyPart.responder_service` and `ReplyPart.responder_instance` name the target, `ReplyPart.payload`
  or `ReplyPart.error` is set. A target's hub-side failure is a failed part: `ErrorCode.HANDLER_DISCONNECTED` (it left,
  also while its request was still queued: the request is not moved to another instance),
  `ErrorCode.RESOURCE_EXHAUSTED`.
- **One `ReplyEnd`** follows when every target answered, when `Request.max_results` > 0 successful parts arrived, or at
  the deadline (`Request.timeout_ms` under the usual rules, for the whole gather), whichever is first:
  `ReplyEnd.parts` (failed ones included), `ReplyEnd.failed`, `ReplyEnd.timed_out` (targets without an answer at the
  deadline). `ReplyEnd.error` is unset for a gather: partial answers are answers. Answers after the end are dropped. A
  gather that ends early (`Request.max_results`, the deadline, the sender gone) sends `Cancel{<id>#<n>, reason}`
  (`max results`, `deadline`, `sender disconnected`) to each still-forwarded target; a still-queued target leaves its
  queue, uncancelled.
- Parts and the end reach the sender in order, also when its buffer is full (they wait for room up to 5 s each, like
  terminal messages).
- A library must collect the parts until the `ReplyEnd`, and, on the handler side, abort a target's work on its
  `Cancel` and send nothing more for it (`L1-SCATTER`).

| Situation | Sender sees |
|---|---|
| No live target (unknown type, or owners without instances) | `Error{NO_HANDLER}`, no `ReplyEnd` |
| The type is a command (request kind or registered kind) | `Error{INVALID_REQUEST}` |
| A mode hub.proto does not define | `Error{INVALID_REQUEST}` |
| `Request.id` (or a derived `<id>#<n>`) already in flight | `Error{INVALID_REQUEST}` "duplicate id" |
| The sender disconnects | the gather and its targets end; late answers are dropped |

### Streaming

A sender sends a query `Request` with `Request.mode` = `RequestMode.STREAMING`, `Request.initial_credit` (0 reads as
64), `Request.max_results` (0 = no limit) and `Request.timeout_ms`; one handler streams the result back under the
sender's credits:

```text
sender                                   hub                                        handler (one instance)
  Request{id=s, mode=STREAMING,     -->    Request{id=s#1, mode=STREAMING,     -->  b1 (service B)
          initial_credit=2}                        initial_credit=2}
                                   <--    ReplyPart{s, seq 1, B/b1, payload}  <--  ReplyPart{s#1, seq 1, payload}
                                   <--    ReplyPart{s, seq 2, B/b1, payload}  <--  ReplyPart{s#1, seq 2, payload}
  Flow{s, credits 2}               -->    Flow{s#1, credits 2}                -->  (the handler resumes)
                                   <--    ReplyPart{s, seq 3, ...}            <--  ReplyPart{s#1, seq 3, ...}
                                   <--    ReplyEnd{s, parts 3}                <--  ReplyEnd{s#1}
```

- **Target:** exactly one instance, chosen as for a point query among the live instances that list the type.
- **The handler gets** `Request{id = <id>#1, mode = STREAMING, initial_credit = <credit>}` with the sender's payload,
  headers, priority, routing key and timeout; `Request.max_results` is 0 (the hub enforces it). Flow control, queues,
  priority and session buffers apply to that forward as for any request, and the target holds its handler permit from
  the forward until the stream ends.
- **Parts and the end:** the handler sends `ClientMessage.part` (a `ReplyPart` for `<id>#1` with its payload and its
  own `ReplyPart.seq`) and `ClientMessage.end` (a `ReplyEnd` for `<id>#1`, with `ReplyEnd.error` when it failed). The
  hub relays each to the sender in order, also when the sender's buffer is full (the end never overtakes a part):
  `ReplyPart.request_id` becomes the sender's id, `ReplyPart.responder_service` and `ReplyPart.responder_instance` name
  the handler, `ReplyPart.seq` is kept. `ReplyEnd.parts` counts the parts the hub relayed; an error on the handler's
  end is relayed as `ReplyEnd.error`. Parts and ends for an unknown id, from an instance that is not the target, or for
  a request that is not streaming are ignored.
- **Credits:** the hub keeps the remaining credit (the initial credit plus every sender `Flow{<id>, credits}`, each
  relayed to the handler as `Flow{<id>#1, credits}`); every part takes one. A `Flow` for an unknown id, from anyone but
  the sender, or with 0 credits is ignored.
- **A library must** (`L1-STREAM`): on the handler side, number its parts 1, 2, 3, ... per request with no gap
  (`ReplyPart.seq`), send no more parts than the credit it was given (a part beyond it ends the stream with
  `ErrorCode.INVALID_REQUEST` "part without credit"), stop at a `ServerMessage.cancel`, and
  bound how long it waits for credit (a hub that forgot the stream, after a lost `Flow` or `Cancel`, would otherwise
  hold the handler and its permit forever; both official libraries end the stream with `ErrorCode.TIMEOUT` "no credit
  within ..." after 10 minutes); on the sender side, grant `Request.initial_credit` and refill it with `Flow` as the
  caller consumes (both official libraries send `Flow{max(1, initial / 2)}` after every `max(1, initial / 2)` parts
  consumed), send `Cancel` when the caller stops reading, and detect lost parts: the hub drops a part it cannot
  deliver to a full sender buffer in time and counts it anyway, so a gap in `ReplyPart.seq`, or a clean `ReplyEnd`
  whose `ReplyEnd.parts` is more than the parts received, is a loss that fails the stream (both official libraries
  cancel it and report the lost parts).
- **Endings** (the sender gets at most one `ReplyEnd`, the handler at most one `Cancel`):

| Situation | Sender sees | Handler sees |
|---|---|---|
| The handler sends `ReplyEnd` | `ReplyEnd{parts}`, with the handler's `error` if any | nothing |
| A part carrying `error` | `ReplyEnd{error}` (the part is not relayed) | nothing: it ended |
| A part beyond the credit | `ReplyEnd{error = INVALID_REQUEST "part without credit"}` | `Cancel{<id>#1, "part without credit"}` |
| `Request.max_results` > 0 parts relayed | `ReplyEnd{parts}` | `Cancel{<id>#1, "max results"}` |
| `ClientMessage.cancel` with `Cancel{<id>, reason}` from the sender | nothing more | `Cancel{<id>#1, reason}` |
| No part within `Request.timeout_ms` (usual rules; from the forward, reset by every part, paused while the sender's credit is exhausted and restarted by the `Flow` that raises it; a queue wait is bounded by it too) | `ReplyEnd{error = TIMEOUT}` | `Cancel{<id>#1, "idle timeout"}` (if forwarded) |
| Open for the hub's maximum stream duration (10 min by default) | `ReplyEnd{error = CANCELLED "max stream duration (10m) exceeded"}` | `Cancel` with that reason |
| The handler disconnects (also while the target was still queued) | `ReplyEnd{error = HANDLER_DISCONNECTED}` | - |
| The target cannot be forwarded (full queue or buffer) | `ReplyEnd{error = RESOURCE_EXHAUSTED}` | - |
| The sender disconnects | - | `Cancel{<id>#1, "sender disconnected"}` (if forwarded) |
| The stream ends between the pop of its queued target and the write to the handler | as above | `Cancel{<id>#1, "closed before forward"}` right after the `Request` (never a `Cancel` before it) |
| The hub shuts down | every session is closed, as for unary requests | |
| A unary `Reply` to the target (a handler that does not stream) | one `ReplyPart` with `seq` 1 then `ReplyEnd{parts 1}`; `Reply{error}` as `ReplyEnd{error}` | nothing |

| Situation | Sender sees |
|---|---|
| The request's kind is `RequestKind.COMMAND` | `Error{INVALID_REQUEST}` |
| No owner, or owners without a live instance that lists the type | `Error{NO_HANDLER}` |
| The type is registered as a command | `Error{INVALID_REQUEST}` |
| `Request.id` or `<id>#1` already in flight | `Error{INVALID_REQUEST}` "duplicate id" |

The gates apply in that order (request kind, target, registered kind, duplicate id): a registered command type with no
live instance gets `ErrorCode.NO_HANDLER`; an unknown type with a duplicate id gets `ErrorCode.NO_HANDLER`.

### Subscription

A sender sends a query `Request` with `Request.mode` = `RequestMode.SUBSCRIPTION`, `Request.initial_credit` (0 reads
as 64), `Request.max_results` (0 = no limit) and `Request.timeout_ms`; every handler instance pushes its updates, one
of them also answers the initial result:

```text
sender                                   hub                                            targets (every live instance of every owner)
  Request{id=w, mode=SUBSCRIPTION,   -->    Request{id=w#1, mode=SUBSCRIPTION}       -->  a1 (service A)
          initial_credit=2}                 Request{id=w#2, mode=SUBSCRIPTION}       -->  b1 (service B)
                                            Request{id=w#0, mode=UNARY, timeout_ms}  -->  b1 (the initial result, chosen as a point query)
                                   <--    ReplyPart{w, seq 1, B/b1, payload}         <--  Reply{w#0, payload}
                                   <--    ReplyPart{w, seq 2, A/a1, payload}         <--  ReplyPart{w#1, seq 1, payload}   (an update)
  Flow{w, credits 2}               -->    (nothing to the targets: updates are pushed)
                                   <--    ReplyPart{w, seq 3, B/b1, payload}         <--  ReplyPart{w#2, seq 1, payload}
                                                                                     <--  ReplyEnd{w#1}                    (a1's emitter completed)
                                   <--    ReplyEnd{w, parts 3}                       <--  ReplyEnd{w#2}                    (the last target)
```

- **Targets:** every live instance of every owner (exclusive or shared) that lists the type, as they are at the open:
  an instance registering later is not added and a target that leaves is not replaced (updates are delivered **at most
  once**; the hub never resubscribes).
- **Each target gets** `Request{id = <id>#n, mode = SUBSCRIPTION}` (`n` = 1, 2, ... in target order: service, then
  instance id) with the sender's payload, headers, priority, routing key and timeout, `Request.initial_credit` and
  `Request.max_results` 0, **written directly**: a subscription is passive, so it takes no permit, waits in no queue
  and is not counted as a forwarded request. A target whose session buffer is full at the open is left out; when none
  could be written the subscription ends with `ReplyEnd{error}` carrying the last failure's code
  (`ErrorCode.RESOURCE_EXHAUSTED` for a full buffer, `ErrorCode.HANDLER_DISCONNECTED` if that session is gone). Every
  target is written **before** the initial request (`<id>#n` before `<id>#0` on the same instance), and a close cancels
  only the targets already written (one that is written after the close gets `Cancel{"closed before forward"}` after
  its `Request`).
- **The initial result:** one of the targets, chosen as for a point query among them, also gets
  `Request{id = <id>#0, mode = UNARY}` with the sender's `Request.timeout_ms` and priority, through flow control,
  queues and priority like any unary request, holding its handler permit. Its `Reply{payload}` reaches the sender as
  `ReplyPart{<id>, seq 1, responder_*}`; `Request.timeout_ms` (usual rules) bounds only this request (queue wait plus
  handler). The handler of a subscription type recognises the initial request by its `#0` id and answers any other
  unary request with `ErrorCode.INVALID_REQUEST`.
- **Updates:** a target sends `ClientMessage.part` (a `ReplyPart` for `<id>#n`) per update and `ClientMessage.end` (a
  `ReplyEnd` for `<id>#n`, with `ReplyEnd.error` when it failed) when its emitter completes. The hub relays the updates
  to the sender in arrival order with its **own** `ReplyPart.seq` (2, 3, ... after the initial part; the handlers'
  `seq` is dropped), the request id rewritten to the sender's, `ReplyPart.responder_service` and
  `ReplyPart.responder_instance` naming the target, in order also when the sender's buffer is full. Updates that
  arrive before the initial result wait behind it (the initial part is always `seq` 1). A target's clean `ReplyEnd`
  removes it; the last target's clean end ends the subscription with `ReplyEnd{parts}` (the hub's count, initial part
  included) once the buffered updates are out. Parts and ends for an unknown id, from an instance that is not that
  target, and a unary `Reply` to an update target are ignored.
- **Credits and buffer:** the sender's credit is `Request.initial_credit` (64 when 0) plus every `Flow{<id>, credits}`;
  the initial part takes one, every update one. Updates beyond the credit (or before the initial part) are buffered
  per subscription, up to the hub's subscriber buffer (256 by default); one more ends it (table below). A `Flow`
  drains the buffer in order. Nothing is relayed to the targets: updates are pushed, and a slow sender is the hub's
  problem, not the emitters'. A `Flow` for an unknown id, from anyone but the sender, or with 0 credits is ignored.
- **A library must** (`L1-SUBSCRIBE`), on the handler side: register a subscription synchronously when its `<id>#n`
  request is read, before any admission check, and buffer emits until the admission is decided (the hub writes `#n`
  before `#0` to the same instance, so an update emitted after the initial result was read is never lost); remove it
  on a `ServerMessage.cancel`; end it with `ReplyEnd` when its emitter completes (with `ReplyEnd.error` when it
  failed); and refuse a subscription beyond its own limit with `ReplyEnd{error = RESOURCE_EXHAUSTED}` (both official
  libraries: 1024 per instance). On the sender side: return the initial result, then the updates, and refill credit
  counting the initial part as consumed (`Flow{max(1, initial / 2)}` after every `max(1, initial / 2)` parts, as for a
  stream, so a window of 1 works), and detect lost parts as for a stream (the hub numbers a subscription's parts 1, 2,
  3, ... itself).
- **Endings** (the sender gets at most one `ReplyEnd`, each target at most one `Cancel`):

| Situation | Sender sees | Targets see |
|---|---|---|
| The last target sends a clean `ReplyEnd` (earlier ones end silently) | `ReplyEnd{parts}`, after the buffered updates | nothing |
| Any target sends `ReplyEnd{error}` or a part carrying `error` | `ReplyEnd{error}` (the part is not relayed) | `Cancel{<id>#n, "target <instance> failed"}` to the others |
| The initial request fails: `Reply{error}`, no reply within `timeout_ms`, its handler gone, a capacity rejection | `ReplyEnd{error}` with that error, no part | `Cancel{<id>#n, "initial result failed"}` |
| The subscriber buffer is full and one more update arrives | `ReplyEnd{error = RESOURCE_EXHAUSTED "subscriber buffer (256) exceeded"}` (the buffered updates are dropped) | `Cancel{<id>#n, "subscriber buffer exceeded"}` |
| `Request.max_results` > 0 updates relayed (the initial part does not count) | `ReplyEnd{parts}` (what is still buffered is dropped) | `Cancel{<id>#n, "max results"}` |
| `ClientMessage.cancel` with `Cancel{<id>, reason}` from the sender | nothing more | `Cancel{<id>#n, reason}`; `Cancel{<id>#0, reason}` while the initial request is still forwarded |
| The sender disconnects | - | the same, with `"sender disconnected"` |
| A target disconnects | nothing (silent) | - |
| The last target disconnects | `ReplyEnd{error = HANDLER_DISCONNECTED}` | `Cancel{<id>#0}` if the initial request is still forwarded elsewhere |
| Open for the hub's maximum subscription duration (off by default) | `ReplyEnd{error = CANCELLED "max subscription duration (<d>) exceeded"}` | `Cancel` with that reason |
| No update for a long time | nothing: there is no idle timeout | |
| The hub shuts down | every session is closed, as for unary requests | |

| Situation | Sender sees |
|---|---|
| The request's kind is `RequestKind.COMMAND` | `Error{INVALID_REQUEST}` |
| No owner, or owners without a live instance that lists the type | `Error{NO_HANDLER}` |
| The type is registered as a command | `Error{INVALID_REQUEST}` |
| `Request.id`, `<id>#0` or a pending `<id>#n` already in flight | `Error{INVALID_REQUEST}` "duplicate id" |
| A target already serves the hub's limit of subscriptions per instance (1024 by default) | `Error{RESOURCE_EXHAUSTED}` naming the instance |

The gates apply in that order, all before anything is sent. An update target's id is no pending id (it is matched
through its subscription), so a later request with that id is routed normally.

### Cancel

`Cancel` ends a stream or a subscription:

- **From the sender** with its `Request.id` (`Cancel.request_id`): no `ReplyEnd` follows. A `Cancel` reaches only the
  hub the request was sent through.
- **From the hub to a handler** with the target's id (`<id>#n`) when the request ended; `Cancel.reason` says why. A
  scatter-gather target may get one too. The handler stops and sends nothing more for that id; a `Cancel` for an id
  that already ended is ignored.
- A point query or a command cannot be cancelled: hub.proto has no `Cancel` for them.

### A lost stream

When a stream is lost, a library must cancel the streaming handlers and remove the subscriptions that arrived on it
(the hub forgot them with the session) and fail the streams and subscriptions it sent through it (they are bound to
that hub); unary handlers may run on, their replies dropped (`L1-LOST-STREAM`). Neither official library resubscribes:
the caller subscribes again and gets a fresh initial result.

## Several hubs

A deployment may run several hubs; they never talk to each other. Each routes only to the instances with a stream to
it, so availability comes from every instance connecting to every hub with the same registration. The hub's side is in
[Operations, High availability](../server/operations.md#high-availability).

A library connected to several hubs must (`L1-HUBS`):

- open **one stream per hub**, each with its own handshake, heartbeat and reconnect backoff, all with the identical
  `Register`;
- know each hub by `RegisterAck.hub_id`; for an empty `hub_id` (a real hub always names itself), by its target as
  `host:port`, with a `static://` prefix (and in the Rust library `http://` or `https://`) stripped and a resolved IPv6
  address written `[ip]:port` without a zone. The first target to
  acknowledge a `hub_id` owns it while it is kept, live or reconnecting; a later target answering the same id is closed
  and parked (its `Register` has already replaced the owner's session, so the owner reconnects once) and is retried
  only once the owner is gone;
- send replies on the stream the request arrived on.

It routes (`L1-HUB-ROUTING`): an unkeyed request round-robin over the hubs whose stream is acknowledged (reconnecting
hubs are skipped). A request with a routing key must go to the live hub with the highest rendezvous score for
`(hub_id, routing key)`, with exactly the function below: scores compared as unsigned 64-bit numbers, equal scores won
by the smaller hub id, compared as bytes (hub ids are ASCII). A key then keeps its hub while the hubs are stable, and only the keys of a hub
that leaves move. Why it must be the same function in every library: each hub picks the instance of a key from its
own ring, and the rings agree only while every instance is registered on every hub; while memberships differ (an
instance reconnecting, a rolling deploy), two hubs can pick two instances for one key. When every sender, in any
language, sends a key through the same hub, one ring decides and the per-aggregate affinity holds. The function, as
both official libraries implement it, with their shared test vectors:

```text
score(hub_id, key) = fmix64(fnv1a64(utf8(hub_id) ++ [0x00] ++ utf8(key)))
fnv1a64: h = 0xcbf29ce484222325; for each byte b: h = (h ^ b) * 0x100000001b3   (wrapping)
fmix64:  k ^= k >> 33; k *= 0xff51afd7ed558ccd; k ^= k >> 33; k *= 0xc4ceb9fe1a85ec53; k ^= k >> 33
winner:  the highest score as an unsigned 64-bit number; equal scores: the smaller hub_id, compared as bytes (ASCII)
test vectors: ("", "") -> 0xb9034ad37056f5fb, ("hub-1", "order-42") -> 0x5c855509f5ad7c8d,
              ("hub-2", "order-42") -> 0xd109ca177e04ae14
```

It splits its permits (`L1-HUB-PERMITS`):

- N counts the hubs that are live or still on their first connect attempt (a first attempt that fails counts as gone).
  A stream offers `ceil(max / N)` initial permits, `max` being the instance's local capacity.
- When N shrinks (a hub went down, failed its first attempt, was parked as a duplicate or was drained), every live
  stream gets `Permits{count = max(0, ceil(max / N) - offered), grant = ceil(max / N)}`, offered being what that stream
  already offered the hub (its `Register.initial_permits` plus earlier top-ups). The grant raises the hub's cap on the
  session before the count is added, so with two hubs the survivor of an outage serves at full capacity, and repeated
  flaps never add up. A hub that joins or returns gets `ceil(max / N)` on its new stream. Nothing is ever revoked; the
  instance's local bound stays `max`.

It fails over (`L1-HUB-FAILOVER`): a request never handed to a stream's transport (the stream dropped before the client
noticed, or the request still sat in the library's outbound buffer) goes to the next hub with the same id: it was never
sent. A unary request a hub answers with `ErrorCode.NO_HANDLER` was never delivered, so the other live hubs get it in
turn, each at most once and within the caller's remaining timeout, in the same order the request chose its first hub
by (a keyed request: descending rendezvous score; an unkeyed one: round-robin order from its hub); if all decline,
the last answer comes back at once.
Streaming queries and subscriptions are bound to the hub they were sent through.

**Addresses.** The official libraries take a list (`static://hub:7000,hub-2:7000`) or one `dns:///name:port`
re-resolved every 30 s. A DNS answer is reduced to its IPv4 addresses when it has any, else its IPv6 ones, without
repeats: a dual-stack name lists every hub under both families, and two streams of one instance id to one hub replace
each other. An address that leaves the DNS answer leaves the routing at once, gets a `Register` with no types, and is
closed once nothing of the instance is in flight on it.

## Instance status

At least every 5 s a library must send `ClientMessage.status` (an `InstanceStatus`) on every stream (`L1-STATUS`); it may send more, for example at once when its set of live hubs changes:

- `InstanceStatus.connected_hub_ids`: the `RegisterAck.hub_id` of every hub it holds an acknowledged stream to, this
  one included;
- `InstanceStatus.handlers_in_flight`: handlers running now, over all hubs;
- `InstanceStatus.processors`: one `ProcessorStatus` per event processor it started ([Processor status](#processor-status));
  an empty list says "no processor started" (the hub replaces the list, never merges).

The hub keeps the latest report per session, bounded (at most 64 hub ids of at most 128 bytes, 32 processors, 1024
segments, 16 capabilities and 256 event types each; longer strings are cut at a UTF-8 boundary as hub.proto lists), and
drops the excess without an error to the client. The topology and the dashboard show it and flag an instance missing a
hub.

## Processor status

Only a library that runs event processors (level 3,
[feature-levels.md](feature-levels.md)) reports them. One `ProcessorStatus` per processor (`L3-STATUS`):

| Field | Content |
|---|---|
| `ProcessorStatus.name` | `default` for the handlers without a processing group, else the group name (`[a-z0-9][a-z0-9-]{0,47}`) |
| `ProcessorStatus.subscription`, `ProcessorStatus.source` | the event store's name for the processor's subscription and the source it reads |
| `ProcessorStatus.event_store`, `ProcessorStatus.capabilities` | the event-store add-on's name (`kafka`, `rabbitmq-streams`, `memory` or a third party's) and what it declares (`replay`, `browse`, `lag`, `native-dead-letter` or its own names) |
| `ProcessorStatus.state` | a `ProcessorState`, by the rules of hub.proto: `ProcessorState.PROCESSOR_STARTING` before its first assignment or during a reassignment (a revocation not yet followed by an assignment), `ProcessorState.PROCESSOR_RUNNING` (an instance whose assignment is empty is idle, running), `ProcessorState.PROCESSOR_FAILING` when a record exhausted its attempts in the last 60 s or the reader reports an error, `ProcessorState.PROCESSOR_STOPPED` (shutdown, or out of its subscription while a reset holds the lock), `ProcessorState.PROCESSOR_PAUSED`; never `ProcessorState.PROCESSOR_STATE_UNSPECIFIED`, which the hub uses for a value it does not know |
| `ProcessorStatus.segments` | one `SegmentStatus` per segment assigned to this instance, in the hub's segment order: decimal names by value, then the rest by bytes; positions are the event store's opaque strings, empty when unknown; `SegmentStatus.lag` -1 when unknown |
| `ProcessorStatus.processed_total`, `ProcessorStatus.failed_total` | counters since the instance started |
| `ProcessorStatus.dead_letters` | the processor's letters in the message store, over all instances, sampled every 30 s; 0 when `ProcessorStatus.dead_letter_mode` is not `collection` |
| `ProcessorStatus.last_error`, `ProcessorStatus.last_error_at_ms` | the latest failure's message (never a payload or a stack trace) and when |
| `ProcessorStatus.event_types` | the event types the processor's handlers handle, sorted |
| `ProcessorStatus.dead_letter_mode` | `collection`, `event-store` or `log` |
| `ProcessorStatus.replaying`, `ProcessorStatus.operation_id`, `SegmentStatus.replay_until` | an open replay range, and the reset operation holding the processor's lock |

A segment name longer than 128 bytes is dropped by the hub and a longer position reads as unknown, so an event-store
add-on keeps both within 128 bytes ([event-store-add-ons.md](event-store-add-ons.md)).

## Processor control

The hub is a stateless control plane: it relays an operator's call to the instances that report the processor and
turns their answers into one HTTP answer ([Processor control](../server/processor-control.md)). The state lives in the
service's message store, which every instance reads at start and every 5 s, so an instance that missed a request
converges.

A library that runs event processors must handle each `ServerMessage.control` off the stream's read loop (never
blocking heartbeats or request dispatch), one request per processor at a time, log it at INFO, and answer with exactly
one `ClientMessage.control_reply` carrying the same `ControlReply.control_id`, on the stream it arrived on
(`L3-CONTROL`). The hub gives up after 10 s (`ControlRequest.reset_execute`: 120 s) and drops a late reply.

`ControlRequest.control_id` is chosen by the hub (a UUID) and `ControlRequest.processor` names the processor
(`default` included). The actions, and what answers each:

| `ControlRequest.action` | The instance | Answer |
|---|---|---|
| `ControlRequest.pause` | persists "paused" and stops consuming without leaving the subscription | `ControlReply.ok` |
| `ControlRequest.resume` | persists "not paused" and consumes again | `ControlReply.ok` |
| `ControlRequest.reset_prepare` | takes the processor's lock for `ResetPrepare.operation_id` until `ResetPrepare.lease_ms` from now and leaves the subscription; the same operation again renews the lease | `ControlReply.ok` once it left; `ControlRefusal.CONTROL_REFUSAL_LOCKED` when another operation holds the lock; `ControlRefusal.CONTROL_REFUSAL_NOT_PREPARED` for an operation that already ended on it, or a renewal whose lock is gone |
| `ControlRequest.reset_execute` | moves the subscription's committed positions to `ResetExecute.target`, sent to one instance that holds `ResetExecute.operation_id` | `ControlReply.reset` |
| `ControlRequest.reset_finish` | releases the lock of `ResetFinish.operation_id` and consumes again, still paused if it was; `ResetFinish.aborted` is true when the operation was aborted | `ControlReply.ok`, also when nothing is held; `ControlRefusal.CONTROL_REFUSAL_NOT_PREPARED` when another operation is held |
| `ControlRequest.dead_letter_list` | lists the processor's dead letters, oldest first, without payloads or headers (`DeadLetterList.limit` 1 to 100; the hub clamps) | `ControlReply.dead_letters` |
| `ControlRequest.dead_letter_retry` | retries the letter `DeadLetterRetry.letter_id` | `ControlReply.retry` |
| `ControlRequest.dead_letter_retry_all` | retries every letter of the processor | `ControlReply.retry_all` |
| `ControlRequest.dead_letter_discard` | discards the letter `DeadLetterDiscard.letter_id` | `ControlReply.ok` when it existed, `ControlRefusal.CONTROL_REFUSAL_NOT_FOUND` when it did not |

**The target of a reset** (`ResetTarget.to`, a oneof). Anything but `ResetTarget.latest` is a replay of the records
between the target and the committed positions before the reset:

- `ResetTarget.earliest`: every segment's first position;
- `ResetTarget.latest`: every segment's head; never a replay;
- `ResetTarget.timestamp_ms`: the first position at or after this time, epoch milliseconds (the head where no record is
  that late);
- `ResetTarget.positions`: explicit `SegmentPosition` pairs (`SegmentPosition.segment`, `SegmentPosition.position`); a
  segment not listed keeps its committed position.

**What the answers carry:**

- `ControlOk.detail`: free text for the operator, at most 512 bytes.
- `ResetOutcome.ranges`: one `ReplayRange` per segment that replays (`ReplayRange.segment`; the records at a position
  `ReplayRange.from` <= position < `ReplayRange.until` are a replay), empty for `ResetTarget.latest`;
  `ResetOutcome.markers_deleted`: the processed-event markers the reset deleted; `ResetOutcome.reset_handlers`: how many
  reset handlers ran.
- `DeadLetterPage.letters`: at most `DeadLetterList.limit` letters, oldest first; `DeadLetterPage.total`: every letter
  of the processor.
- `DeadLetterSummary`: `DeadLetterSummary.id`, `DeadLetterSummary.processor`, `DeadLetterSummary.source`,
  `DeadLetterSummary.segment`, `DeadLetterSummary.position` (empty when unknown), `DeadLetterSummary.key`,
  `DeadLetterSummary.event_id`, `DeadLetterSummary.event_type`, `DeadLetterSummary.reason` (`HANDLER_FAILED`,
  `SEQUENCED` or `INVALID`), `DeadLetterSummary.error_type`, `DeadLetterSummary.error_message` (at most 512 bytes),
  `DeadLetterSummary.blocked_by` (a `SEQUENCED` letter: the id of the letter of the same key it waits behind),
  `DeadLetterSummary.attempts`, `DeadLetterSummary.parked_at_ms`, `DeadLetterSummary.last_attempt_at_ms`. Never a
  payload or a header.
- `DeadLetterRetryOutcome.result`: `"Retried"`, `"Duplicate"` (the event's marker existed: the letter is deleted),
  `"Failed"`, `"Blocked"`, `"NotRetriable"` (an `INVALID` letter) or `"NotFound"`; `DeadLetterRetryOutcome.detail`:
  for `"Failed"` the error (at most 512 bytes), for `"Blocked"` the id of the head letter.
- `DeadLetterRetryAllOutcome.retried`, `DeadLetterRetryAllOutcome.failed`, `DeadLetterRetryAllOutcome.blocked`,
  `DeadLetterRetryAllOutcome.skipped`: per key in position order, a key stops at its first failure (its later letters
  count as blocked); `INVALID` letters are skipped.

Refusals (`ControlReply.refused`: a `ControlRefused` with `ControlRefused.code` and `ControlRefused.message`, at most
512 bytes, never a payload):
`ControlRefusal.CONTROL_REFUSAL_UNKNOWN_PROCESSOR` (no such processor here; to a prepare or a finish it means "not
involved"), `ControlRefusal.CONTROL_REFUSAL_LOCKED` (another operation holds the lock; the message names it),
`ControlRefusal.CONTROL_REFUSAL_NOT_PREPARED` (above), `ControlRefusal.CONTROL_REFUSAL_SUBSCRIBERS_ACTIVE` (another
instance still reads the subscription; the message lists them), `ControlRefusal.CONTROL_REFUSAL_RESET_HANDLER_FAILED`
(a reset handler failed; the message says how many ran), `ControlRefusal.CONTROL_REFUSAL_INVALID` (a bad target, a bad
letter id, a dead-letter mode other than `collection`, a limit out of range), `ControlRefusal.CONTROL_REFUSAL_FAILED`
(anything else, with the reason; `lease lost: ...` when the executor's lease was lost mid-execute),
`ControlRefusal.CONTROL_REFUSAL_NOT_FOUND` (a letter that does not exist), `ControlRefusal.CONTROL_REFUSAL_UNSUPPORTED`
(the event store lacks the capability the request needs, see `ProcessorStatus.capabilities`). A library never sends
`ControlRefusal.CONTROL_REFUSAL_UNSPECIFIED`: the hub reads a code it does not know as it. A refusal changes nothing
unless its message says what did: a `reset_execute` refused after its reset handlers ran ends with "reset handlers ran
(n), m markers deleted, positions not moved: retry the reset".

What each action does inside the instance (the lease, the reset steps, replay ranges, dead-letter sequencing) is the
library's contract, in [writing-a-library.md](writing-a-library.md).

## Timing summary

The client-side values of both official libraries, next to the hub's defaults they follow (the hub's own settings are
in [Server settings](../server/configuration/server.md)):

| Parameter | Value |
|---|---|
| Heartbeat interval | `RegisterAck.heartbeat_interval_ms` (3 s by default); 3 s before the ack |
| Client handshake timeout | 10 s without a `RegisterAck`: close and reconnect |
| Client gives up a silent hub | no echo for 3 heartbeat intervals (9 s) |
| HTTP/2 keepalive, client side | ping every 10 s, timeout 5 s, also while idle |
| Client-side request guard | the hub's bound for the type (override or maximum) + 1 s |
| Client reconnect backoff | 500 ms doubling to 5 s, ±20 % jitter (never above the maximum), back to 500 ms once an attempt reached the handshake; a refusal waits 80 to 100 % of the maximum |
| Client permit grants | one per completed handler; sent at once while the hub holds `min(16, initial_permits / 2)` or fewer of the instance's permits, else batched at 16 or after 50 ms |
| Instance status | every 5 s on every stream |
| JWT renewal | at 80 % of the token's lifetime |
| Streaming handler credit wait | 10 min, then `ErrorCode.TIMEOUT` |
| Subscriptions served per instance | 1024 |
| Default stream credit | 64 |

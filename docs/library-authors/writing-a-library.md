# Writing a Snodra library

This page is for anyone writing a Snodra library for a new language (Go, TypeScript, Python, C#, ...). After reading
it you know in which order to build one so that each step can be tried against a real hub, the states a connection, a
request, a stream and a subscription go through, and the mistakes the official libraries made on the way, each as a
rule with its reason. The protocol itself is in [protocol.md](protocol.md), the messages in [messages.md](messages.md),
the levels and their checks in [feature-levels.md](feature-levels.md). The Kotlin and Rust libraries are reference
implementations ([Kotlin](../messaging/kotlin/index.md), [Rust](../messaging/rust/index.md)), never the specification.

## Before you start

- **Bindings.** Generate the gRPC types and the `Hub.Connect` client from
  [`proto/hub.proto`](https://github.com/snodra/snodra-server/blob/main/proto/hub.proto) with your language's protobuf and gRPC tooling. You need
  bidirectional streaming and HTTP/2 keepalive pings.
- **A hub to try against.** The `snodra-server` image runs with its defaults (plain text, access control off, gRPC on
  port 7000, dashboard on 7001); its dashboard shows your instance, its types, permits and status as the hub sees them.
- **A name.** `snodra-messaging-<language>` is the suggested name for a community library
  ([index.md, Add your library](index.md#add-your-library)).

## Build order

Each step ends with something to try against a real hub; levels are in [feature-levels.md](feature-levels.md).

1. **Types and payloads**: message type names, the JSON codec with the payload rules
   ([messages.md](messages.md)).
2. **One stream**: `Register`, `Heartbeat`, the `RegisterAck`, the heartbeat cadence, the silent-hub check,
   reconnect with backoff, registration refusals ([protocol.md, Connect and register](protocol.md#connect-and-register)).
   Watch the instance appear on the dashboard and come back after a hub restart.
3. **Handling unary requests**: dispatch by type, the error mapping, one terminal message per request, permits
   ([protocol.md, Handling a request](protocol.md#handling-a-request), [Flow control](protocol.md#flow-control)).
4. **Sending unary requests**: request ids, the pending map, timeouts, never sent versus outcome unknown, the error
   codes ([protocol.md, Requests](protocol.md#requests)). Two instances of your library can now talk, and so can yours
   and an official one.
5. **Identity and propagation**: the forwarded `authorization` header, its validation before the handler, the
   correlation id and trace context ([messages.md](messages.md#request-headers)).
6. **Credentials**: a static token, then a JWT with its refresh, then client certificates and TLS
   ([protocol.md, Credentials](protocol.md#credentials)).
7. **Query modes**: shared types and scatter-gather (nothing new on the handler side), then streaming, then
   subscriptions ([protocol.md, Query modes](protocol.md#query-modes)).
8. **Several hubs**: one connection per hub, routing, the permit split and top-up, failover, `InstanceStatus`
   ([protocol.md, Several hubs](protocol.md#several-hubs)). This completes **level 1**.
9. **Events**: the message-store interfaces with an in-memory store and the store kit, the event-store interfaces with
   an in-memory event store and its kit, the outbox relay, the consumer ([level 2](#level-2-events)). Port the kits
   first: they are the specification of the add-ons ([event-store-add-ons.md](event-store-add-ons.md),
   [message-store-add-ons.md](message-store-add-ons.md)).
10. **Processors**: named processors, status, control, dead letters, replay ([level 3](#level-3-processors)).
11. **Sagas** and deadlines ([level 4](#level-4-sagas)).

## State machines

### A connection to one hub

```mermaid
stateDiagram-v2
    [*] --> Connecting
    Connecting --> AwaitingAck: stream open, Register and Heartbeat written
    Connecting --> Backoff: connect failed
    AwaitingAck --> Live: RegisterAck
    AwaitingAck --> Rejected: closed with ALREADY_EXISTS, INVALID_ARGUMENT, UNAUTHENTICATED or PERMISSION_DENIED
    AwaitingAck --> Backoff: no ack within the handshake timeout, or the stream failed
    Live --> Live: Heartbeat every interval, later Register acked, credentials refreshed
    Live --> Backoff: stream failed or closed, or no echo for three intervals
    Rejected --> Connecting: after the backoff cap, reason kept
    Backoff --> Connecting: after the wait (reset to the floor if the last attempt reached Live)
    Live --> Draining: shutdown (empty Register first, then handlers drained and subscriptions ended in either order, half-close)
    Draining --> [*]: hub finished its side, or the drain timed out
    Connecting --> [*]: shutdown
    AwaitingAck --> [*]: shutdown
    Backoff --> [*]: shutdown
    Rejected --> [*]: shutdown
```

Requests may arrive in AwaitingAck: serve them. On every transition out of Live, the requests written to the stream
have an unknown outcome, the ones still in the library's own buffer were never sent, and the streams, subscriptions and
handlers bound to the stream end ([protocol.md, A lost stream](protocol.md#a-lost-stream)).

### A unary request the library sends

```mermaid
stateDiagram-v2
    [*] --> Built: fresh Request.id
    Built --> NeverSent: no live stream
    Built --> Buffered: queued for a live stream
    Buffered --> NeverSent: stream lost before the transport took it
    Buffered --> Pending: handed to the transport
    Pending --> Answered: Reply with payload
    Pending --> Failed: Reply with error, or the hub's Error
    Pending --> TimedOut: local guard (hub bound + 1 s)
    Pending --> Unknown: stream lost
    Pending --> Built: NO_HANDLER from one hub, another hub left (the next hub in the ranking, same id)
    NeverSent --> Built: another hub, same id (or a retry, fresh id)
    NeverSent --> [*]: no hub left, failed as never sent
    Answered --> [*]
    Failed --> [*]
    TimedOut --> [*]
    Unknown --> [*]
```

A request is pending until exactly one of a reply, an error or its local guard; a late answer for an id no longer
pending is dropped.

### A stream, on both sides

```mermaid
stateDiagram-v2
    state "Sender" as S {
        [*] --> Open: Request mode STREAMING, initial_credit
        Open --> Receiving: ReplyPart
        Receiving --> Receiving: ReplyPart, Flow after every half window consumed
        Open --> Done: ReplyEnd, or Error before a target
        Receiving --> Done: ReplyEnd (with or without error)
        Open --> Cancelled: caller stops, Cancel sent (no ReplyEnd follows)
        Receiving --> Cancelled: caller stops, Cancel sent (no ReplyEnd follows)
        Open --> Failed: stream lost
        Open --> Failed: local guard timeout (Cancel sent)
        Receiving --> Failed: stream lost
        Receiving --> Failed: local guard timeout, or a lost part (Cancel sent)
    }
    state "Handler" as H {
        [*] --> Sending: the forwarded Request, with initial_credit
        Sending --> WaitingForCredit: credit spent
        WaitingForCredit --> Sending: Flow
        Sending --> Ended: ReplyEnd sent (error on failure)
        WaitingForCredit --> Ended: no credit within the bound, ReplyEnd TIMEOUT
        Sending --> Stopped: Cancel from the hub, or stream lost
        WaitingForCredit --> Stopped: Cancel from the hub, or stream lost
    }
```

The handler holds its permit from the request to Ended or Stopped, and sends nothing after Stopped.

### A subscription, on both sides

```mermaid
stateDiagram-v2
    state "Sender" as S {
        [*] --> Subscribing: Request mode SUBSCRIPTION, initial_credit
        Subscribing --> Open: first ReplyPart (the initial result, seq 1)
        Subscribing --> Done: ReplyEnd with error, or Error before any target
        Subscribing --> Cancelled: caller stops, Cancel sent
        Subscribing --> Failed: stream lost
        Subscribing --> Failed: local guard timeout on the initial result (Cancel sent)
        Open --> Open: ReplyPart (update), Flow counting the initial part
        Open --> Done: ReplyEnd
        Open --> Cancelled: caller stops, Cancel sent
        Open --> Failed: stream lost
        Open --> Failed: a lost part (Cancel sent)
    }
    state "Handler target" as T {
        [*] --> Registered: its Request read (registered at once)
        Registered --> Active: admitted, buffered emits delivered
        Registered --> Refused: ReplyEnd with error (limit, identity, wrong mode)
        Active --> Active: emit, one ReplyPart each
        Active --> Ended: emitter completes, ReplyEnd (error on failure)
        Registered --> Removed: Cancel from the hub, or stream lost
        Active --> Removed: Cancel from the hub, or stream lost
    }
```

The initial result is a separate unary request `<id>#0` to one of the targets, served like any unary request; the
target recognises it by its `#0` id.

## Pitfalls the official libraries met

Each is a rule, with the reason it exists and the check that proves it.

**Connection**

- **Treat the `RegisterAck` as the handshake, never the heartbeat echo** (`L1-HANDSHAKE-ACK`). Clients first treated the
  echo as the registration's confirmation; the ack replaced it
  because it carries what the client must apply (the heartbeat interval, the timeout rules, the hub id), and the hub
  writes it before the echo of the heartbeat that follows the `Register`. A client that went live on an echo would
  heartbeat and time out on guesses, and could not tell two targets of one hub apart.
- **Serve requests that arrive before the ack** (`L1-EARLY-REQUESTS`): the hub routes to an instance as soon as its
  `Register` is processed, so dropping them fails a sender's request for nothing.
- **A refused `Register` is not fatal** (`L1-REJECTION`): two services registering one type is a deployment error; a
  service that crashed on it would turn one bad deploy into an outage, and one that retried at once would hammer the
  hub. Retry at the backoff cap and say why.
- **Leave the hubs in order at shutdown** (a should, not checked yet;
  [protocol.md, Shutting down](protocol.md#shutting-down)): first a `Register` with no types to every hub, so the hub
  routes what it queued for the instance elsewhere at once instead of when the session ends; then end the served
  subscriptions and drain the handlers, in either order; then half-close each stream, waiting (bounded) for the hub to
  finish its side. Dropping
  the stream resets the RPC and discards what the transport had not written yet, such as a subscription target's last
  updates and its `ReplyEnd`; the hub would then fail the subscription with `ErrorCode.HANDLER_DISCONNECTED`.

**Requests**

- **Send exactly one terminal message per request id** (`L1-ONE-TERMINAL`). The hub matches answers by id and drops
  what comes for an id it no longer waits for; a request left without its terminal message keeps the sender waiting
  until its timeout and keeps the permit counted; anything sent after the hub's `Cancel` is for an id the hub already
  forgot.
- **Answer on the stream the request arrived on** (`L1-ARRIVAL-STREAM`). After a reconnect the new stream is another
  session: the hub accepts an answer only from the session it forwarded the request to, and has already failed the
  request with `ErrorCode.HANDLER_DISCONNECTED`.
- **A failed nested call is the handler's `ErrorCode.HANDLER_ERROR`** (`L1-HANDLER-ERRORS`). `ErrorCode.NO_HANDLER`
  tells a sender that no handler ran, which makes a command safe to retry; a handler that passed its own downstream
  `ErrorCode.NO_HANDLER` through would get a command that already did part of its work run again.
- **Check the caller before decoding the payload** (`L1-IDENTITY`), so an anonymous caller cannot learn payload
  shapes from the decode errors.
- **Send `Request.timeout_ms` = 0 unless the caller chose a timeout** (`L1-TIMEOUT`). When clients always sent a
  value, the hub's per-type timeouts could never apply. The local
  guard waits one second longer than the hub's bound, so the hub's answer, which says what happened, normally comes
  first.
- **A retry never sends 0 as its timeout** (`L1-RETRY`): 0 means "the hub's default", which can be longer than what
  is left of the caller's budget. Send the remainder, at least 1 ms.
- **Only what never left your own buffer was never sent** (`L1-NEVER-SENT`, `L1-HUB-FAILOVER`). A request still in the
  library's outbound buffer when its stream breaks can go to another hub with the same id; one the transport took may
  be on the wire, and resending it could run a command twice.

**Flow control and several hubs**

- **Give a permit back at once when the hub runs low** (`L1-PERMITS`): with batching alone, an instance with one
  permit is paced by the batching timer at about 20 requests per second.
- **Split permits over the hubs and top them up when one goes** (`L1-HUB-PERMITS`). Each hub holds the permits of its
  own session and never learns that another hub went down; without the top-up and its `Permits.grant`, the survivor
  keeps its share as a cap and the instance runs at a fraction of its capacity after an outage. Offering at most the
  new share per stream keeps repeated flaps from adding up, and never revoking keeps a hub's queue from stalling.
- **One address family from DNS, one stream per `RegisterAck.hub_id`** (`L1-HUBS`). A dual-stack name lists every hub
  twice, and two streams of one instance id to one hub replace each other at the hub, over and over.

**Query modes**

- **Register a subscription the moment its `<id>#n` request is read** (`L1-SUBSCRIBE`), before checking the caller,
  and buffer emits until that check is done. The hub writes `#n` before `#0` to the same instance; a library that
  registered later lost the updates emitted between serving the initial result and registering.
- **Count the initial part as consumed when refilling a subscription's credit** (`L1-SUBSCRIBE`): it took a credit at
  the hub, and a window of 1 never refills otherwise.
- **Bound a streaming handler's wait for credit** (`L1-STREAM`): a hub that forgot the stream (a lost `Flow` or
  `Cancel`) never sends credit, and the handler would hold its task and its permit forever.

**Credentials**

- **Refresh a JWT once per renewal** (`L1-JWT`): the hub looks at one refresh per second per session and drops the
  rest without a reply, so a burst hides the one that mattered. After `UNAUTHENTICATED`, register with a newly fetched
  token (the old one is what the hub refused); after `PERMISSION_DENIED`, do not fetch again (a new token for the same
  client would be refused the same way, and the identity provider is not to be hammered).
- **Reconnect with a renewed client certificate before `notAfter`** (`L1-MTLS`): a TLS session cannot be refreshed on a
  live stream, so the hub closes it at `notAfter` with no grace. The official libraries watch the files, wait a random
  delay so replicas do not all leave at once, and roll their hubs over one at a time.
- **A token file is read again before every connect**, and an empty file after a good read is a rotation caught half
  way: keep the last good token (not checked yet: a library's own test).

**Events and processors**

- **Record the processed-event marker and run the handlers in one transaction, and acknowledge after its commit**
  (`L2-CONSUME`): an acknowledgement before the commit loses the event on a crash; a marker outside the transaction
  either skips an event whose handling rolled back or handles it twice.
- **An event-store subscription's `next` must lose nothing when its wait is dropped** (`L2-EVENT-STORE-KIT`): the core
  races it with its shutdown and its timers and drops the losing wait, so an event or an error held inside a dropped
  wait is gone (the Kotlin kit cancels `next` after every slice of reading to catch exactly this).
- **Close what you built when a subscribe is cancelled** (the Kotlin interface says so; not checked yet: no kit check
  cancels a subscribe): a subscription built and then dropped stays a member of the event store's subscription,
  holding segments nobody reads.
- **Handle control requests off the stream's read loop, and answer a lease renewal at once, even during an execute**
  (`L3-CONTROL`, `L3-RESET`): a control action can take seconds or minutes; on the read loop it would stop heartbeats
  and request dispatch, and a renewal queued behind a long execute would let the lock expire under it.
- **Remember the reset operations that ended, and refuse their late renewals** (`L3-RESET`) with
  `ControlRefusal.CONTROL_REFUSAL_NOT_PREPARED`: a renewal that raced the finish would otherwise take the free lock for
  a whole lease and stop every instance.

## Level 2: Events

What a library adds for events:

- **Publish**: build the event (its type, a fresh id, the key, the headers of
  [messages.md](messages.md#event-headers)) and append it to the outbox in the caller's transaction (`L2-OUTBOX`).
- **Relay**: every instance runs a relay that claims pending outbox entries under a lease, in `(created_at, seq)`
  order, hands each to the event store with the stored key and headers plus `type`, `id`, `timestamp` and `source`,
  and marks it sent once the event store accepted it. Several instances compete without leader election; an entry may
  be sent twice if an instance dies between the publish and the mark, which consumers absorb.
- **Consume**: per processor, one subscription; per delivery, skip (and acknowledge) a type no handler handles,
  otherwise record the marker and run the handlers in one transaction, then acknowledge (`L2-CONSUME`). A failing
  handler is retried with backoff, then the record becomes a dead letter (level 3) or, at level 2, is logged and
  skipped.
- **Startup**: a service with only command, query and subscription-query handlers needs neither store; anything that
  publishes or handles events without them fails at startup naming the missing add-on (`L2-NO-ADD-ON`).

## Level 3: Processors

What a library adds for processors:

- **Named processors** (`L3-PROCESSORS`): handlers without a processing group run in `default`, the others in their
  group's processor, each with its own subscription and markers; sagas run only in `default`.
- **Status** (`L3-STATUS`): every status tick, one `ProcessorStatus` per processor, built from memory, never blocking
  the stream or the consumer ([protocol.md, Processor status](protocol.md#processor-status)).
- **Pause and resume** (`L3-PAUSE`): persisted in the message store's processor control, which every instance reads at
  start and every 5 s; consumption stops without leaving the subscription.
- **Reset** (`L3-RESET`), leased: prepare takes the lock and leaves the subscription; execute (on one instance) plans
  the target with the event store, refuses while members still read the subscription, runs the processor's reset
  handlers when anything replays, deletes the processor's markers in the replay ranges, stores the ranges, then moves
  the positions; finish releases the lock and consumes again. An instance whose lease passes without a renewal
  releases the lock and resumes by itself; an instance that starts under a held lock does not join the subscription
  until the lock is gone. An event store without `replay` answers `ControlRefusal.CONTROL_REFUSAL_UNSUPPORTED`.
- **Replay** (`L3-REPLAY`): while a segment's delivery is below its range's end, the processor's handlers run except
  those marked not to replay, and sagas are skipped; the range closes once the committed position reaches its end.
- **Dead letters** (`L3-DEAD-LETTERS`): a record that exhausts its attempts is parked in the message store (mode
  `collection`, the default), sent to the event store's dead-letter source (`event-store`) or logged and skipped
  (`log`). Letters are `HANDLER_FAILED`, `SEQUENCED` (an earlier letter of the same key is parked: the record waits
  behind it, so order per key holds) or `INVALID` (no type, a payload that is not a JSON object: discard only). The
  hub lists, retries and discards them through control requests.

## Level 4: Sagas

Sagas live in the library, inside the service that owns them, so the hub only ever sees the commands a saga sends, never the saga itself (the
programming model is in [Sagas and deadlines](../messaging/index.md#sagas-and-deadlines)). What the rest
of Snodra sees of them:

- A saga's commands and events are recorded in its transaction and relayed after the commit, in order per saga, at
  least once; each command carries `idempotency-key` and `saga-id`, and no caller token (`L4-SAGA-DISPATCH`).
- A redelivered event is applied once per saga type (`L4-SAGA-ONCE`); a command that fails for good comes back as a
  local event (`L4-COMMAND-FAILED`); deadlines fire once over every instance (`L4-DEADLINES`).
- The adapters' failure markers in `Error.details` travel across the hub (`L4-ADAPTER-MARKERS`,
  [messages.md, Handler errors](messages.md#handler-errors)).

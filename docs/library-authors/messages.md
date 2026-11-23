# Messages: names, payloads and headers

This page is for anyone writing a Snodra library, or a service in a language without one: it describes what a
message is on the wire, whatever carries it (a hub `Request`, or an event in an event store). After reading it you can
name message types, encode payloads that every other library reads, set and propagate the headers (correlation id,
trace context, the acting user), and report a handler's failure so the caller can act on it. The stream that carries
commands and queries is in [protocol.md](protocol.md).

There are three kinds of messages. An **event** states that something happened; it is published through the message
store's outbox to the event store, and any number of services may handle it, later. A **command** asks exactly one
service to do something and returns a response; a **query** asks for data. Commands and queries go through the hub
([protocol.md](protocol.md)); a query may also be answered as a stream, a gather or a subscription
([protocol.md, Query modes](protocol.md#query-modes)).

## Type names

Every message has a type name, the one thing the hub routes on and an event consumer dispatches on.

| Rule | Example |
|---|---|
| A type name is `<service prefix>.<Name>` | `orders.PlaceOrder` |
| Events are past tense | `orders.OrderPlaced`, `orders.OrderCancelled` |
| Commands are imperative | `orders.PlaceOrder`, `orders.CancelOrder` |
| Queries start with Get, Find or List | `orders.GetOrder`, `orders.FindOrderById`, `orders.ListOrders` |
| A response class is named `<CommandOrQuery>Result` (it has no type name of its own on the wire) | GetOrderResult |

- **Names are explicit and stable.** The official libraries let a message declare its wire name (Kotlin
  `@MessageType`, Rust `message_type!`, Go a `MessageType()` method), so that a class can be renamed without changing the contract. Senders and
  handlers in any language agree on the text, nothing else.
- **A type has one kind while it is owned.** A type registered as a command cannot be registered as a query by another
  instance (`ALREADY_EXISTS`). A streaming query is a query type to the hub (the mode is the sender's choice). A
  subscription query is a query type its service also declares in `Register.subscription_query_types`, and the hub
  serves it in `RequestMode.SUBSCRIPTION` only ([protocol.md, Subscription types](protocol.md#subscription-types)).
- **Reserved namespace.** `snodra.events.*` belongs to the event browser
  ([event-store-add-ons.md, The event browser's queries](event-store-add-ons.md#the-event-browsers-queries)): with the
  hub's access control on, only a credential with the `event-browser` right may register those types.

## Payloads

Payloads are UTF-8 JSON documents, in `Request.payload`, `Reply.payload`, `ReplyPart.payload` and the event store's
record value. The hub never reads them. For every library to read every other's:

- field names in `camelCase`;
- timestamps as ISO 8601 strings in UTC (`2026-10-28T14:03:22Z`);
- ids as strings (UUID or ULID);
- unknown fields ignored on read, so adding an optional field is backward compatible;
- never rename or remove a field without introducing a new message type;
- a command without a result answers `{}`.

**An event's payload is a JSON object** whose integers fit in a signed 64-bit integer: the message store's outbox
refuses anything else (not JSON, an array, a bare value, a larger integer), and also a depth over 100 (counted as
MySQL's `JSON_DEPTH`: `{"a":1}` is 2), a number no double holds, a lone surrogate escape, a leading byte order mark and
bytes that are not UTF-8; so does every store add-on
([message-store-add-ons.md](message-store-add-ons.md#the-rule)). Payloads cross the libraries' store and event-store
interfaces as JSON bytes, never as a database's own document format.

The owning service publishes the shape of each type: the `*-api` module of a Kotlin service, the documented contract
of a Rust one.

## Request headers

`Request.headers` is a map of strings, forwarded by the hub unchanged. hub.proto names the known keys:

| Header | Content |
|---|---|
| `authorization` | `Bearer <JWT>` of the acting user ([Forwarded identity](#forwarded-identity)); absent when there is none |
| `correlationId` | ties together everything one action caused ([Correlation id](#correlation-id)) |
| `traceparent`, `tracestate` | W3C trace context ([Trace context](#trace-context)) |

- These headers are the library's own: a library must refuse a call that sets one of them through its generic header
  option, before anything is sent (`L1-PROPAGATION`). The reserved names are `authorization`, `traceparent`,
  `tracestate`, `correlationId` and `correlation-id`, compared ignoring letter case (`AUTHORIZATION` and
  `CORRELATIONID` are refused too); the official libraries refuse exactly these. A caller may add any other header,
  and the handler sees it.
- A saga's commands carry `idempotency-key` (`<sagaId>:<seq>`) and `saga-id`, and no `authorization`; an idempotent
  adapter uses `idempotency-key` to act once (`L4-SAGA-DISPATCH`).

## Event headers

Every event carries seven headers, as the event store's native metadata (record headers, message properties: the
event-store add-on decides how). A library must set them all on every
event it publishes (`L2-HEADERS`):

| Header | Content |
|---|---|
| `type` | the event's type name |
| `id` | the event id (a UUID): the key of every duplicate check |
| `correlationId` | the correlation id of the message being handled when the event was published; a new UUID when there is none |
| `timestamp` | when the event was created (not when it was sent), RFC 3339 in UTC, always with milliseconds, a whole second too (`2026-10-28T14:03:22.000Z`) |
| `source` | the publishing service's name (not the event store's source) |
| `userId` | the acting user's id; empty when there is none (a system event) |
| `traceparent` | the W3C trace context of the work that published it |

- **Only `userId` crosses into events, never the token**: events outlive tokens and are read later, by many services.
- The event key (the order key) is not a header: it is the event store's key, typically the aggregate id. Events with
  the same key reach a processor in the order the event store received them; that is the publish order of one
  instance while one relay sends its outbox
  ([message-store-add-ons.md](message-store-add-ons.md#the-rule)).
- A header is UTF-8 text with one value per name. A record that carries anything else (a library never publishes one)
  is not preserved byte for byte.
- An event parked in the event store's dead-letter destination (dead-letter mode `event-store`) keeps its key, payload
  and headers and gains six headers saying why and where it came from: `snodra-dlt-processor`, `snodra-dlt-reason`,
  `snodra-dlt-error`, `snodra-dlt-original-topic` (the source), `snodra-dlt-original-partition` (the segment) and
  `snodra-dlt-original-offset` (the position). The library's core writes them, so the
  names are the same on every event store (`topic`, `partition` and `offset` in them are older names of the source, the
  segment and the position); a record's own header of one of these names is replaced. The letter's event id is the
  record's `id` header, or `<source>-<segment>-<position>` for a record without one (or with a blank one), in both
  libraries.

## Correlation id

A correlation id ties together a user's action and everything it caused, across services and over time. A library must
carry it on (`L1-PROPAGATION`):

- a request or an event sent while a request or an event is being handled carries that message's `correlationId`;
  when the message being handled carries none, its own id stands in: `Request.id` for a request, the event id (header
  `id`) for an event;
- one sent outside any handling gets a new UUID;
- a saga's commands carry the correlation id of the message that caused them, a deadline's work the one of the message
  that scheduled it; a deadline with an empty correlation id is stored and read as one without, on every store, and its
  own id stands in.

## Trace context

`traceparent` and `tracestate` are W3C trace context, so a handler's span is a child of its sender's. The hub parents
its own `hub.route` span on the request's `traceparent` and forwards the request with the original value.

The contract is a floor: a request or an event sent while a message is handled must carry a W3C `traceparent` of that
message's trace, either the incoming one or one of a child span of it (`L1-PROPAGATION`). Only a valid one is
forwarded: version `00`, lower-case hex (`00-<32 hex>-<16 hex>-<2 hex>`), neither the trace id nor the parent id all
zeros; an invalid one is dropped, never passed on, and the message is sent without one. A saga's commands and events
carry the `traceparent` of the event that caused them. A deadline keeps no headers, so the work a deadline handler sends
carries no `traceparent`. Sending `tracestate` and creating spans are optional. The reference implementations differ
above that floor:

- the Kotlin library, with Micrometer Tracing on the classpath and configured, writes the current trace context through
  its propagator (`traceparent`, and `tracestate` when the propagator emits it); without it, it forwards the valid
  `traceparent` of the message being handled, unchanged;
- the Rust library forwards the valid `traceparent` of the message being handled, unchanged, and creates no span of its
  own.

## Forwarded identity

The acting user's JWT travels in the
`authorization` header (`Bearer <token>`) of every hub request; the hub does not read it.

- **Sender:** a request sent while a request is being handled carries that request's `authorization` header on, so a
  downstream service acts for the same user (`L1-PROPAGATION`). A request without a user (a scheduler, an event-driven
  follow-up, a saga's command) carries none.
- **Handler:** a token is the caller's identity only once it is verified against the issuer's JWKS, exactly as the
  service validates a REST call (signature, expiry, issuer):
    - **A guard needs a JWKS.** A handler that requires an authenticated caller (any caller, a role, a given caller)
      cannot be registered in a service without a JWKS: that is a startup error naming the handler (a library's own
      test: the runner sees no startup).
    - **Without a JWKS no token is an identity.** Its claims are never read into a caller: the caller is anonymous, and
      the token is only carried on by the requests the handler sends.
    - **Every request's token is checked first**, before the handler is looked up: for every handler, guarded or not,
      and for a type the instance does not serve. A token that fails is `ErrorCode.UNAUTHENTICATED`, never
      `ErrorCode.NO_HANDLER`. With a JWKS a token fails when it does not verify, also when the JWKS endpoint is down
      (`ErrorCode.UNAUTHENTICATED` for the caller, never an internal error). With or without a JWKS, a request fails
      when its `authorization` header is not `Bearer <token>` ("malformed authorization header"; the scheme is matched
      in any letter case, and a blank header is no token), and when the token is not a signed compact JWS. With a JWKS
      the message is the verifier's; without one the texts are: five segments, an encrypted token ("unsupported
      token"); not three segments, a header or claims segment that is not base64url of a JSON object, or an `alg` that
      is not a string ("unreadable token"); `alg` `none` or an empty signature ("unsigned token").
    - **An anonymous caller is refused before the payload is decoded**, so it cannot probe payload shapes
      (`L1-IDENTITY`): no identity, for a handler that requires one, is `ErrorCode.UNAUTHENTICATED`. The handler's
      rule (a role, a given caller) is applied once the payload is decoded, since a rule may read the message: an
      authenticated caller it refuses is `ErrorCode.PERMISSION_DENIED`, and a payload that does not decode is
      `ErrorCode.INVALID_REQUEST` for any authenticated caller, also one with the wrong role.
- **A request answered in-process** ([protocol.md, Requests a service answers itself](protocol.md#requests-a-service-answers-itself))
  shows its handler the caller the hub path would carry (the token the library would forward, for example that of the
  request being handled), else an anonymous caller.
- The **service's** own credential (a token, a JWT or a certificate on the hub stream) is a different thing: it says
  which service connects, not who acts ([protocol.md, Credentials](protocol.md#credentials)).

## Handler errors

A handler's failure reaches the sender as an `Error` in the `Reply` (or in the `ReplyEnd` of a stream or a
subscription target), with `Error.request_id` the request's id ([protocol.md, Handling a request](protocol.md#handling-a-request)):

- `Error.code`: `ErrorCode.HANDLER_ERROR` for anything the handler raised; `ErrorCode.UNAUTHENTICATED` and
  `ErrorCode.PERMISSION_DENIED` for the caller's identity; `ErrorCode.INVALID_REQUEST` for a payload that does not
  decode or a request in the wrong mode; `ErrorCode.NO_HANDLER` for a type this instance does not serve. A failure of a
  call the handler made itself is the handler's `ErrorCode.HANDLER_ERROR`, never passed through with its own code
  (`L1-HANDLER-ERRORS`).
- `Error.message`: a short human-readable text, safe to log, never a stack trace. The Kotlin library writes
  `<ExceptionSimpleName>: <message>`.
- `Error.details`: optional machine-readable JSON. The Kotlin library puts a JSON array of the violation messages there
  for a validation failure. Two values are reserved by the saga runtime:
  `{"snodra":"retryable"}` (an adapter asks for a later attempt) and `{"snodra":"unknown-outcome"}` (an adapter cannot
  tell whether the external call happened). A library at level 4 must write and read them exactly
  (`L4-ADAPTER-MARKERS`).
- A sender that reads a code its library does not know treats it as `ErrorCode.HANDLER_ERROR` (the official libraries
  do).

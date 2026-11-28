---
title: "Schema catalogue"
---

The live list of the message contracts the connected services declare, the version rules the router applies to
requests, and the dashboard page, JSON API and gRPC service that show it.

> **Compatibility.** The hub keeps the catalogue on by default and then refuses a `Register` that carries no
> contracts. The released Kotlin, Rust, Go and Python libraries do not send contracts yet, so a hub with the
> default setting refuses their handler instances (and the event browser add-on, which registers query types the
> same way). Run the hub with `SNODRA_SERVER_CATALOG=off` until the library you use declares contracts, or pin an
> earlier server release. See [Switching it off](#switching-it-off).

## What a contract is

A **contract** is the triple `(type, payload version, response version)` for one command or query type, with the
JSON Schema of its payload and of its response. A version of 0 (unset) reads as 1. An **event contract** is
`(type, payload version)` and one schema; events have no response.

A service instance declares its contracts in its `Register`:

| Field | Content |
|---|---|
| `Register.contracts` | one `MessageContract` for every type in `command_types`, `query_types` and `shared_query_types`: its `kind`, `shared` and `subscription` flags (which must agree with the lists the type appears in), `payload_version`, `response_version`, `payload_schema`, `response_schema` and `schema_override` |
| `Register.event_contracts` | one `EventContract` for every event type the instance consumes: `type`, `payload_version`, `payload_schema`, `schema_override` |

The hub never parses a payload. It stores the schemas for the catalogue and routes by the two version headers of the
request, never by content.

### Schema documents

- JSON Schema 2020-12, as UTF-8 bytes; the top level must be a JSON object.
- At most 64 KiB, nested at most 100 levels deep. A document over either limit, or one that is not JSON or whose top
  level is not an object, refuses the `Register` (`INVALID_ARGUMENT`; the message says which limit or rule).
- The hub checks those rules and nothing else: it does not interpret the schema or validate payloads against it.
- The hub stores the **canonical form**: every object's keys sorted, no insignificant whitespace. Two documents
  that differ only in key order or whitespace are the same schema.
- The **hash** is the lowercase hexadecimal SHA-256 of the canonical document, computed by the hub (a client never
  sends one). It is for display and for spotting equal documents; it is never used for routing.
- `schema_override` says the schema is a checked-in one rather than generated from the message type. It is
  informational: the hub keeps it for the dashboard, and it takes no part in routing or in comparing contracts.

## Versions on requests

A request names the contract it speaks in two headers of `Request.headers`:

| Header | Meaning |
|---|---|
| `snodra-schema-version` | the payload version the sender speaks |
| `snodra-response-schema-version` | the response version the sender expects |

- An absent header reads as 1.
- A present value must be ASCII digits `[1-9][0-9]*` that fit an unsigned 32-bit integer: no sign, no leading zero,
  no whitespace. Anything else is `INVALID_REQUEST` (`invalid request: snodra-schema-version must be a positive
  integer`, or the same for `snodra-response-schema-version`) before any instance gets anything.
- The hub passes both headers to the handler unchanged and adds none to the reply: the reply is the requested
  response version, because the hub only routes to an instance that serves the exact contract.
- **Every request mode routes only to instances serving the exact `(type, payload version, response version)`**:
  unary, scatter-gather, streaming and subscription. A scatter-gather's targets are the instances serving it.
- When no live instance serves the requested contract but the type has others, the sender gets `NO_HANDLER` naming
  the versions that are live:

  ```text
  no handler for orders.PlaceOrder (payload 1, response 1); live: (payload 2, response 2)
  ```

  Several live contracts are listed with commas, in version order. When the type has no live contract at all, the
  answers are the usual ones: `no handler registered for type ...`, or `owner known, no instance for service ...`
  inside the owner grace ([Routing](/docs/server/routing/)).

## The live catalogue

The catalogue is **per hub, in memory and live**. A contract exists while at least one instance with a stream to
this hub serves it. When the last instance serving it leaves, the contract is removed with it, and the version
number can be used again, with a different schema.

A `Register` whose contract clashes with a live one is refused as a whole, and nothing of it is recorded:

| Situation | Refusal |
|---|---|
| A live contract with the same `(type, payload version, response version)` has a different payload or response schema, served by any instance, the registering instance included (a re-registration counts) | `FAILED_PRECONDITION` ("a changed schema needs a new version"); the refusal is listed as a recent conflict |
| The same for an event contract | `FAILED_PRECONDITION` |
| A type in `command_types`, `query_types` or `shared_query_types` without a contract, on a hub with the catalogue on | `INVALID_ARGUMENT`, with a hint to upgrade the library or set `SNODRA_SERVER_CATALOG=off` |
| A contract for a type the `Register` does not declare as a command or query | `INVALID_ARGUMENT` |
| Two contracts for one type, or two contracts for one event type | `INVALID_ARGUMENT` |
| A contract whose `kind`, `shared` or `subscription` flag disagrees with the lists, or whose kind is unspecified | `INVALID_ARGUMENT` |
| A schema over the limits, not JSON or not an object; an event contract with no type | `INVALID_ARGUMENT` |

The same schema from a second instance is not a conflict: it joins the contract's instances. Each refused
`Register` is counted in `snodra_server_register_refused_total{reason}`
([Observability](/docs/server/observability/)).

### Events

Consumers register event contracts; they appear in the catalogue with the services and instances that consume
them. Events are never routed through the hub, and a service that only publishes an event type is not listed for
it.

## Switching it off

`SNODRA_SERVER_CATALOG` is `on` (the default) or `off`, in any letter case; anything else stops the hub at startup.

With `off`:

- contracts and event contracts in a `Register` are ignored, and a declared type needs none;
- both version headers are ignored, and every type is served as payload version 1, response version 1: routing is
  by type name alone;
- the dashboard's Catalogue page says the catalogue is off, `GET /api/v1/catalog` answers `enabled: false` with
  empty lists, `GET /api/v1/catalog/{type}` is 404, and the gRPC `List` is empty and `Get` is `NOT_FOUND`.

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_CATALOG=off \
  snodra/snodra-server:0.7.0
```

## Dashboard

The **Catalogue** page of the [dashboard](/docs/server/dashboard/) shows what the connected services declared:

- **Contracts**: type, kind, payload and response version, the services serving it and the number of live
  instances. A row opens to the two schemas, formatted, each with its short hash (the first 12 characters of the
  SHA-256, the full hash in its tooltip). A schema that is a checked-in override carries an `override` badge.
- **Events**: type, version, consuming services and instances, with the same expandable schema.
- **Recent conflicts**: the last 20 registrations refused because a live contract had a different schema, newest
  first, with the contract, the refused service and instance and the services serving the live one. The card is
  hidden while there are none. A conflict carries no schema and no hash.
- A filter by type or service, kept in the URL (`#/catalog?q=orders`), and the rows you opened (`open=`).

The Types page links a type to its catalogue entry when it has a live contract.

## JSON API

Read with the same token as the other endpoints under `/api/v1/` (the dashboard token, when one is set), JSON in
camelCase, `Cache-Control: no-store`:

| Path | Content |
|---|---|
| `catalog` | `enabled`, `entries[]`, `events[]`, `conflicts[]` |
| `catalog/{type}` | the same shape for one type's contracts and events (`conflicts` empty); 404 `{"error": "..."}` when the type has none, and when the catalogue is off |

An entry: `type`, `kind` (`command` or `query`), `payloadVersion`, `responseVersion`, `payloadSchema` and
`responseSchema` (the canonical documents, as JSON), `payloadHash`, `responseHash`, `schemaOverride`, `services`
and `instances` (sorted). An event: `type`, `version`, `schema`, `hash`, `schemaOverride`, `services`,
`instances`. A conflict: `atMs`, `kind` (`contract` or `event`), `type`, `payloadVersion`, `responseVersion`
(absent for an event), `service`, `instance`, `liveServices`. Entries and events are sorted by type, then versions.

[`/api/v1/types`](/docs/server/dashboard/#json-api) entries carry `contracts`, the number of live contracts of the
type (always 0 with the catalogue off).

## gRPC

The `snodra.hub.v1.Catalog` service is served on the hub port, beside `Hub`, for tooling:

| Call | Answer |
|---|---|
| `Catalog.List` | every live command and query contract, sorted by type, payload version and response version: each with its kind, versions, canonical schemas (bytes), services and instances. Events are not part of it, and there are no hashes |
| `Catalog.Get(type, payload_version, response_version)` | one live contract; a version of 0 reads as 1; `NOT_FOUND` when no instance serves it, `INVALID_ARGUMENT` for an empty type |

A caller authenticates like a hub client. With access control in `enforce`, a call needs an ACL token, a service's
JWT or a client certificate that names a service with an ACL entry, else `UNAUTHENTICATED` (the dashboard token
does not open it). In `permissive` an unauthenticated call is allowed and counted in
`snodra_server_auth_violations_total{reason="catalog_unauthenticated"}`; in `off` the service is open. With the
catalogue off, `List` is empty and `Get` is `NOT_FOUND`.

---
title: "Upgrades"
---

The server is stateless, so a restart is cheap: clients reconnect and re-register. The constraint is
the protocol. Snodra ships one protocol version with no negotiation, and a server and a client of
different builds are not supported. Plan upgrades around that sentence.

## Within one release train

When the protocol package is unchanged, a rolling restart works:

1. Run at least two servers, and point every service at all of them
   (`static://server-1:7000,server-2:7000`).
2. Drain and upgrade one server at a time. On `SIGTERM` it sets health to `NOT_SERVING`, closes its
   streams with `UNAVAILABLE` and drains for up to 5 seconds. Clients fail in-flight requests on that
   server, retry on the other one where the policy allows it, and reconnect.
3. Upgrade services in any order. Each new instance registers with the same types; a re-register with
   the same instance id replaces the old session.
4. Watch `snodra_server_connected_instances`, `snodra_server_registered_types` and the clients'
   `snodra_hub_client_connected_hubs` until every instance is back on every server.

Roll back by running the previous tag. The server stores nothing, so there is no schema to reverse
there.

## Across a protocol change

A release that changes the gRPC package is a coordinated window: the server and every client must
move together. There is no mixed-version mode and no negotiation. Upgrade the server and all services
in the same window, then confirm registration.

## Server 0.7: the schema catalogue

Server 0.7.0 keeps a [schema catalogue](/docs/server/catalog/) by default and then refuses a `Register` that declares
no contracts. The released client libraries do not declare contracts yet, so a 0.7 hub with the default setting
refuses their handler instances (a refusal each service logs and retries; nothing is routed to it). To upgrade the hub
under them, set `SNODRA_SERVER_CATALOG=off` on every hub: contracts and the version headers are then ignored and
routing is by type name alone, as on 0.6. Count refusals in `snodra_server_register_refused_total{reason="missing_contract"}`.
Turn the catalogue on once every service you run declares its contracts.

## Stores and schema

- **MongoDB**: the library writes explicit documents and creates TTL indexes at startup. No migration
  is needed between the Kotlin and Rust libraries.
- **SQL**: the schema is versioned and applied at startup when `init-schema` is true; a service that
  runs its own migration sets it to `false` and the startup checks the version. A schema change is a
  data migration, not an automatic one.
- **Event stores**: events and their record layout are stable across releases. Check the broker's
  retention before a long maintenance window.

## Before you start

- Read the release notes and the [compatibility page](/docs/migration/compatibility/).
- Pin image tags and artifact versions; do not deploy `latest` by accident.
- Export the current dashboards and record the metric names, so a changed instrument is easy to spot
  after the upgrade.
- Keep the previous image and the previous client artifact available for rollback.

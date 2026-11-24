---
title: "Migration"
---

Two things matter when a Snodra deployment moves forward: the version of each component, and the
compatibility rules that make the move predictable.

## Versions

The server and both client libraries ship as one release train. The server reports its version on
`GET /api/v1/version` and the dashboard footer; a client announces its own in `Register.client_version`
for diagnostics only. Every component in a deployment should be on the same release.

Version numbers identify the public artifacts (`snodra-server`, `snodra-messaging`,
`snodra-messaging-rs`, the add-ons and the event browser). A patch release fixes defects and changes
no contract. A minor release may add protocol fields, settings, metrics or handlers, and keeps the
protocol package unchanged. A release that changes the protocol package is a coordinated move for the
server and every client.

## A new minor

A new minor is safe to roll one component at a time when the protocol package (`snodra.hub.v1`) is
the same on both sides:

- **Added settings** have defaults, so an existing configuration keeps working.
- **New metrics and dashboard fields** appear next to the old ones; nothing is removed.
- **New protobuf fields** are optional and ignored by an older peer.
- **Schema changes** are additive. The SQL store's schema version is `1`; `init-schema` applies it
  at startup, and a service that runs its own migration sets it to `false` and the startup check
  requires version `1` or later.

Read the release notes, then follow [Upgrades](/docs/operations/upgrades/) for the rolling procedure.
When a release changes the protocol package, the server and every client move in one window; see
[Compatibility](/docs/migration/compatibility/) for what the package guarantees.

| Page | Answers |
|---|---|
| [Compatibility](/docs/migration/compatibility/) | What `snodra.hub.v1` guarantees and what it deliberately does not |
| [Upgrades](/docs/operations/upgrades/) | How to roll a release through a running deployment |

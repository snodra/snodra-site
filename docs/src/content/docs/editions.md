---
title: "Editions"
---

Snodra is built in the open. The core — the server, the protocol, the client libraries and the event browser — is
open source and stays that way. The paid side is support and the enterprise add-ons, not a locked core.

## Community

Free, for everyone:

- **Snodra Server**: commands, queries, every query mode, several servers, the dashboard, processor control.
- **Go and Python libraries** (feature level 4): commands, queries, events, outbox, consumer, named processors with
  their status, control, reset and replay, dead letters, sagas, deadlines, idempotent external calls and the add-on
  stores.
- **Kotlin and Rust libraries** (feature level 4): the same model, the same wire, and a local dead-letter admin API
  (`DeadLetters` / `app.dead_letters()`; Go and Python list, retry and discard their dead letters through the hub).
- **Snodra Event Browser**: the dashboard's events, records, tails and lag.
- **Snodra Conformance**: the level-1 conformance runner, so anyone can check a new client library.
- **Documentation, examples and the community issue tracker.**

## Enterprise add-ons

Planned, sold separately, and outside the server process wherever possible:

- **SSO and directory sync**: SAML, SCIM, group mapping beyond OIDC.
- **RBAC and policy**: roles, per-type policies, quotas and chargeback.
- **Compliance**: audit export, retention policy, SIEM integrations.
- **Operations**: a Kubernetes operator, backup and restore, long-term-support builds.
- **Multi-tenancy**: isolated namespaces on one deployment.

The protocol and all the client libraries stay fully open: the add-ons add capabilities, they do not gate the core.

## Support and partnerships

- **Support** with SLAs, upgrade assistance and incident response.
- **Consulting and training** for teams adopting the stack.
- **Partner-hosted service**: a partner runs Snodra and earns a referral or revenue share; the trademark and partner
  programme keep the name meaningful.

## Talking to us

The editions are being finalised. For support, a pilot or a partnership, open an issue in the
[`snodra-site`](https://github.com/snodra/snodra-site) repository or write to the maintainer listed there.

## Licence

The open-source core is **Apache-2.0**. The enterprise add-ons will be proprietary. See
[the licence page](/docs/concepts/license/).

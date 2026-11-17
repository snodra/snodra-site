# Editions

Snodra is built in the open. The core — the server, the protocol, both client libraries and the event browser — is
open source and stays that way. The paid side is support and the enterprise add-ons, not a locked core.

## Community

Free, for everyone:

- **Snodra Server**: commands, queries, every query mode, several servers, the dashboard, processor control.
- **Kotlin and Rust libraries**: the same model, the same wire, the Kafka, RabbitMQ Streams, MongoDB, SQL and in-memory
  stores as add-ons.
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

The protocol and both client libraries stay fully open: the add-ons add capabilities, they do not gate the core.

## Support and partnerships

- **Support** with SLAs, upgrade assistance and incident response.
- **Consulting and training** for teams adopting the stack.
- **Partner-hosted service**: a partner runs Snodra and earns a referral or revenue share; the trademark and partner
  programme keep the name meaningful.

## Talking to us

The editions are being finalised. For support, a pilot or a partnership, open an issue in the
[`snodra-site`](https://gitlab.damoreira.ml/snodra/snodra-site) repository or write to the maintainer listed there.

## Licence

The open-source core is MIT today; an Apache-2.0 relicence is planned before v1.0.0, with a contributor licence
agreement so the project keeps its options. The enterprise add-ons will be proprietary. See
[the licence page](concepts/license.md).

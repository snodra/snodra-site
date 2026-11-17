# Licence

Snodra, `snodra-server`, `snodra-messaging` and `snodra-messaging-rs` are released under the **MIT
Licence**, © 2026 Guilherme D'Amoreira. The full text ships in each repository as `LICENSE`.

## What MIT permits

- Use the software commercially and privately.
- Modify it, and distribute your modified version.
- Sublicense it and include it in a larger work.
- No fee, no registration, no contributor licence agreement.

## What it requires

- Keep the copyright notice and the licence text in copies and substantial portions.
- Do not use the authors' names or the project names to endorse your product without permission.

## What it does not provide

- **No warranty.** The software is provided "as is"; the authors are not liable for damages.
- **No patent grant.** MIT is silent on patents, unlike Apache-2.0.
- **No support commitment.** Issues and pull requests are best effort.

## Brand assets

The mascot and logo files under `docs/assets/brand/` are part of the project and covered by the same
licence. If you fork the project, rename it and replace the mascot so users do not confuse your fork
with this one.

## Third-party components

The stack uses Apache Kafka, MongoDB, Keycloak, RustFS, Spring Boot, tonic and librdkafka, each under
its own licence. The hub image contains those dependencies; redistributing it means honouring their
notices. Run `cargo metadata` or the dependency report of each repository for the exact set at a
given tag.

## No affiliation

Snodra is not affiliated with Axon Framework, Axon Server or AxonIQ. Those names appear only to
explain which problem the project addresses and why it is built differently.

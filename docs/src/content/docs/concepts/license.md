---
title: "Licence"
---

Snodra, `snodra-server`, `snodra-messaging` (every language), `snodra-event-browser` and
`snodra-conformance` are released under the **Apache License 2.0**, © 2026 Guilherme D'Amoreira. The full
text ships in each repository as `LICENSE`.

## What Apache-2.0 permits

- Use the software commercially and privately.
- Modify it and distribute your modified version, including inside a larger work, with or without a fee.
- An express patent grant from every contributor.

## What it requires

- Keep the copyright notice, the licence text and any `NOTICE` file in copies and substantial portions.
- State the changes you made to the files you modified.
- Do not use the authors' names or the project names to endorse your product without permission.

## What it does not provide

- **No warranty.** The software is provided "as is"; the authors are not liable for damages.
- **No support commitment.** Issues and pull requests are best effort.
- **No trademark licence.** The names, the mascot and the logo stay the project's; a fork should be renamed
  and its mascot replaced so users do not confuse it with this one.

## Brand assets

The mascot and logo files under `docs/public/assets/brand/` are part of the project and covered by the same
licence. If you fork the project, rename it and replace the mascot.

## Third-party components

The stack uses Apache Kafka, MongoDB, RustFS, Spring Boot, tonic and librdkafka, each under
its own licence. The server image contains those dependencies; redistributing it means honouring their
notices. Run `cargo metadata` or the dependency report of each repository for the exact set at a
given tag.

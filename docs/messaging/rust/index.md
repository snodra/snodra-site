# snodra-messaging-rs

The Rust counterpart of `snodra-messaging`: one builder that opens the hub stream, consumes Kafka,
runs idempotent handlers, publishes through an outbox, and runs sagas with deadlines.

```toml
[dependencies]
snodra-messaging-rs = "0.7"
```

## What it gives you

- One builder for the hub client, Kafka producers and consumers, outbox and handlers.
- Annotated-free, closure handlers: `event`, `event_in`, `command`, `query`, `saga`.
- Idempotent consumption with `processed_events`, named processors, dead letters and the admin API.
- Query modes: unary, scatter-gather, streaming and subscription.
- Static token, OAuth2 / OIDC JWT and mTLS credentials, with rotation.
- `SagaTestFixture` behind the `testing` feature.

## Pages

- [Quick start](quickstart.md) — a service in one file.
- [Configuration](configuration.md) — `SNODRA_*` variables and every hub credential.
- [API](api.md) — handlers, queries, processors and dead letters.
- [Sagas](sagas.md) — the programming model, deadlines, adapters and testing.
- [Testing](testing.md) — the in-memory saga fixture and the integration fixtures.
- [Modules and build](modules.md) — the crate, the example service and CI.

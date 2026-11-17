# Testing

## Testing a saga

Enable the feature `testing` in your dev-dependencies and drive the definition with events and time, in memory, on the
crate's own runtime (no Kafka, MongoDB or hub):

```toml
[dev-dependencies]
snodra-messaging-rs = { path = "../snodra-messaging-rs", features = ["testing"] }
```

```rust
use snodra_messaging::saga::testing::SagaTestFixture;

#[test]
fn a_silent_printer_fails_the_banner_after_30_seconds() {
    SagaTestFixture::new("examples.Banner", banner_saga)    // the closure given to builder.saga
        .given_current_time(t0)
        .given_events(&[&shouted("SILENT-1")])               // what these cause is not expected below
        .when_time_elapses(Duration::from_secs(30))          // fires every due deadline at its own time
        .expect_published_events(&[&BannerFailed { job_id: "banner-silent-1".into(), reason: "TIMEOUT".into() }])
        .expect_saga_ended()
        .expect_no_scheduled_deadlines();
}
```

Steps: `given_events`, `given_current_time` (default 2026-01-01T00:00:00Z), `when_event`, `when_event_with_headers`,
`when_time_elapses`, `when_command_failed(&command, reason, message)` (the relay's `SagaCommandFailed` for a command the saga
sent). Expectations: `expect_active_sagas`, `expect_association`, `expect_dispatched_commands`, `expect_published_events`
(several types in one slice: `&[&A { .. }, &B { .. }]`, compared by wire type and JSON), `expect_scheduled_deadline`,
`expect_no_scheduled_deadlines`, `expect_saga_ended`; `store()` reads the documents. A step that fails (a handler error or
panic, a state that does not survive its JSON text) and an expectation that does not hold **panic**, naming the saga; a
failing step leaves nothing behind. The methods are synchronous: call them from a `#[test]` (or from an async test without
holding the fixture across an `.await`).

## Integration tests

The crate's own suites run against Kafka, MongoDB and `snodra-server:dev` with testcontainers; see [Modules and build](modules.md).

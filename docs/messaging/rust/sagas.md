# Sagas

## Sagas

Sagas, deadlines and the integration toolkit of ADR 0021 (S2): the model of the Kotlin starter (S1), on the same MongoDB
collections and document shapes (`sagas`, `saga_dispatch`, `saga_dispatch_leases`, `deadlines`, `saga_failures`,
`external_calls`, markers in `processed_events`), so a Kotlin and a Rust instance read each other's documents. The
programming model, the delivery guarantees and the command-failure taxonomy are in
[Sagas and deadlines](../index.md#sagas-and-deadlines) (its "Rust"
subsection maps every Kotlin element to this crate); the decisions in
ADR 0021, S2 rulings 47 to 67. The sandbox's banner saga
(`examples/service-c/src/banner.rs`) is a complete example.

A saga is a state type and a definition closure. Handlers are **synchronous** closures that change the state and record
what they want done on the `SagaContext`; the runtime writes the state, the recorded commands and events and the deadlines
in one transaction, and the relay sends them after the commit, in order, with the idempotency key `<sagaId>:<seq>`.

```rust
use snodra_messaging::SagaDefinition;
use snodra_messaging::external::{ExternalSource, IdempotencyKey, TranslatedEvent};
use snodra_messaging::external::kafka::Message; // record.payload(): rdkafka's trait, re-exported
use serde::de::IgnoredAny;

#[derive(Default, Serialize, Deserialize)]   // stored as its serde_json text; must round-trip from Default
struct Banner { job_id: Option<String>, polls: u32 }

fn banner_saga(d: SagaDefinition<Banner>) -> SagaDefinition<Banner> {
    d.start_on::<TextShouted>("jobId", |e| Some(job_id_of(&e.text)), |s, e, ctx| {
        s.job_id = Some(job_id_of(&e.text));
        ctx.send(&PrintBanner { job_id: job_id_of(&e.text), text: e.text.clone() }, None)?; // after commit
        ctx.schedule_after::<()>(Duration::from_secs(30), "print-timeout", None)?;
        Ok(())
    })
    .on::<BannerPrinted>("jobId", |e| Some(e.job_id.clone()), |_, _, _| Ok(()))
    .ending()                                                       // ends after this handler
    .on_deadline::<IgnoredAny>("print-timeout", |s, _, ctx| {
        ctx.publish(&BannerFailed { job_id: s.job_id.clone().unwrap_or_default(), reason: "TIMEOUT".into() }, None)
    })
    .ending()
    .on_command_failed(|s, e, ctx| {                                 // routed by saga id, no association needed
        ctx.publish(&BannerFailed { job_id: s.job_id.clone().unwrap_or_default(), reason: format!("{:?}", e.reason) }, None)?;
        ctx.end();
        Ok(())
    })
}

let app = SnodraMessaging::builder(Config::from_env()?).await?
    .saga("examples.Banner", banner_saga)
    // The adapter: a command handler made idempotent over external_calls (one call per key).
    .idempotent_command::<PrintBanner, _, _>(IdempotencyKey::default(), false, move |c, ctx| {
        let printer = printer.clone();
        async move { printer.submit(&c, &ctx.headers["idempotency-key"]).await }
    })
    // A partner's Kafka topic: records become local events (never republished to kraken.events).
    .external_source("printer-banner", ExternalSource::new("printer.banner.events"), |record| {
        // Malformed never heals: InvalidMessage skips the record at once (a bare `?` is Serialization, retried first).
        let n: Notification = serde_json::from_slice(record.payload().unwrap_or_default())
            .map_err(|e| MessagingError::InvalidMessage(format!("not a printer notification: {e}")))?;
        Ok(Some(TranslatedEvent::new(&BannerPrinted { job_id: n.job_id }, Some(n.delivery_id))?))
    })
    .start()
    .await?;

// A webhook: verify the raw body, then hand the event to the ingress (applied once per dedupe key).
if !snodra_messaging::external::webhook::verify(&secret, None, &headers, &body) { return 401; }
app.ingress().accept("printer-banner", &n.delivery_id, &BannerPrinted { job_id: n.job_id }, &HashMap::new()).await?;
```

**The definition.** `start_on::<E>(key, value, handler)` may start an instance (at most one live instance per start
`key = value`); `start_new_on` always starts one; `on` runs on the live instances associated with `key = value`; the
`*_header` forms (`start_on_header`, `start_new_on_header`, `on_header`) read the value from a message header; `.ending()`
marks the handler just added (event or deadline) as ending the saga; `on_deadline::<P>(name, handler)` gets the payload as
`Option<P>` (take `IgnoredAny` when there is none or it is ignored: `()` reads only `null`); `on_command_failed(handler)` gets
the `SagaCommandFailed` of a command the instance sent. Handlers of one event type run **in registration order**. `start()`
refuses (`InvalidMessage` naming `<saga>.<handler>`) a saga without a start handler, two sagas of one name, an empty name,
`.ending()` with nothing before it, two handlers of one deadline, and a state whose `S::default()` does not round-trip
through its JSON text.

**The context.** `saga_id()`, `message()` (the `MessageContext`; for a deadline its id, `deadline:<name>` and the correlation
id of the message that scheduled it), `associate_with`, `remove_association_with` (removing the start association frees the
start key, also from the start handler), `end()`, `send(&command, routing_key)`, `publish(&event, key)`, `schedule_after(duration, name, payload)`,
`schedule_at(time, name, payload)` (both return the deadline id), `cancel(id)`, `cancel_all(name)`; at most 999 messages per
handling of an instance. A published event must serialize to a JSON object BSON can hold (not a unit struct, no integer
above `i64::MAX`): anything else fails the handler with `InvalidMessage` naming the event. A handler gets no `Sender` or `EventBus`, and **must not capture one**: it would send inside the
saga's transaction, for a state that may roll back, with no order, retry or idempotency key.

**Handlers block.** A saga handler runs on the consumer's task and holds a tokio worker and the partition while it runs:
keep it to recording. A panic is a handler error: two attempts, then the event is parked in `saga_failures`
(`app.saga_failures()`: `list(type)`, `retry(id)`, `retry_all(type)`, `discard(id)`).

**Adapters.** `idempotent_command::<C>(key, external_idempotent, handler)` (and `idempotent_event::<E>`, whose body runs inside
the ordinary handlers' transaction: prefer commands for slow calls) records each call in `external_calls`.
`IdempotencyKey::default()` is the `idempotency-key` header the relay sets; `IdempotencyKey::From(|c, ctx| …)` builds one (a
poll puts its attempt in it). Return `MessagingError::RetryableExternal` for a failure a later attempt may cure (nothing
reached the partner, a 5xx, a 429) and `MessagingError::UnknownOutcome` when the call may have happened (the connection broke
after the request went out); never retry inside the handler. With `external_idempotent = true` the partner de-duplicates by
the key, so a call that crashed mid-way is made again after the lease instead of reported as `UNKNOWN_OUTCOME`. Every handler
of a command a saga sends must be idempotent by `idempotency-key`: a crash between sending and marking it sent sends it again.

**Configuration** (`Config::from_env`, Kotlin's defaults; retentions at least 1 s, intervals at least 1 ms, checked also in a
service without sagas):

| Variable | Default | Meaning |
|---|---|---|
| `SNODRA_SAGAS_ENABLED` | true | `false` with sagas registered: a warning, and no runtime, relay or scheduler |
| `SNODRA_SAGAS_MAX_ATTEMPTS` | 5 | attempts of one (event, saga type) on conflicts before it is parked (200 ms doubling to 5 s); a handler error gets two |
| `SNODRA_SAGAS_ENDED_RETENTION_MS` | 30 d | TTL of ended sagas |
| `SNODRA_SAGAS_DISPATCH_RETENTION_MS` | 7 d | TTL of dispatched `saga_dispatch` entries |
| `SNODRA_SAGAS_RELAY_POLL_INTERVAL_MS` | 500 | how often the relay looks for recorded entries |
| `SNODRA_SAGAS_RELAY_LEASE_MS` | 30000 | one saga's dispatch lease, renewed while a send runs |
| `SNODRA_SAGAS_RELAY_MAX_ATTEMPTS` | 10 | attempts of a command on transient failures before `EXHAUSTED` |
| `SNODRA_SAGAS_RELAY_INITIAL_BACKOFF_MS`, `_MAX_BACKOFF_MS` | 1000, 5 min | the relay's backoff (doubling) |
| `SNODRA_DEADLINES_POLL_INTERVAL_MS` | 1000 | how often due deadlines are looked for |
| `SNODRA_DEADLINES_LEASE_MS` | 30000 | how long a claimed deadline stays reserved (at least once) |
| `SNODRA_DEADLINES_RETENTION_MS` | 7 d | TTL of fired and cancelled deadlines |
| `SNODRA_EXTERNAL_CALLS_LEASE_MS` | 5 min | how long an `IN_PROGRESS` call may take before its outcome is unknown |
| `SNODRA_EXTERNAL_CALLS_RETENTION_MS` | 30 d | TTL of `external_calls` |

Partner sources (`ExternalSource { topic, bootstrap_servers, group_id, properties }`; a key the library fixes in
`properties`, an empty topic or two sources of one name fail `start()`) and the webhook secret are set in code.
`builder.clock(Clock)` replaces the clock of the runtime, the relay, the scheduler, the adapters and the ingress
(`ManualClock` in tests). The runtime, the relay, the scheduler and the gauge sampler run only with a registered saga, the
`external_calls` indexes only with an idempotent handler, a partner consumer per source; `app.ingress()` always exists.
Saga commands to a type the service handles itself go to its own handler without the hub. Shutdown stops the relay, the
scheduler and the sampler first (at most 20 s for the three together), then the rest.

**Deploys and in-flight adapter calls.** At shutdown the relay abandons a send still running after 15 s; the saga's
dispatch lease then lets another instance (or this one, restarted) send the command again with the same key. For a
command delivered to a local idempotent adapter, abandoning the send drops the adapter's future mid-call, so its
`external_calls` record stays `IN_PROGRESS`: the re-send is answered "in progress" (retryable, the relay backs off) until
the record's lease ends (`SNODRA_EXTERNAL_CALLS_LEASE_MS`, 5 min), and then, without `external_idempotent`, the outcome is
unknown and the saga gets `SagaCommandFailed` with `UNKNOWN_OUTCOME` (with the default settings; a relay whose attempts
run out first reports `EXHAUSTED`). With `external_idempotent` the call is run again after the lease. **Keep an adapter's
I/O timeouts under 15 s**, so its calls finish (or fail cleanly) within a deploy's shutdown.

**Statistics.** `app.saga_stats()` has the Kotlin meters as counters and gauges with the same names and labels
(`snodra.sagas.started{type}`, `snodra.sagas.ended{type}`, `snodra.saga.events{type,outcome}`,
`snodra.deadlines.fired{name}`, `snodra.deadlines.due{name}`, `snodra.external.calls{handler,outcome}`,
`snodra.saga.command.failures{type,reason}`, `snodra.sagas.active{type}`, `snodra.saga.dispatch.pending`): typed reads
(`started`, `ended`, `events`, `deadlines_fired`, `deadlines_due`, `external_calls`, `command_failures`, `active`,
`dispatch_pending`) and `snapshot()` for an exporter. The two database-counted gauges are sampled every 15 s. While a saga
handles a message, a `tracing` span `saga` carries `saga_type`, `saga_id` and `correlation_id`.

### Testing a saga

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

### Differences from Kotlin

The behaviour is ADR 0021's rulings 1 to 46; where Rust differs, the S2 ruling says why (rulings 47 to 67):

- Sagas are closures registered on the builder (`builder.saga(name, define)`), not scanned `@Saga` classes; the name is
  required.
- Handlers of one event type run in registration order (Kotlin: method-name order).
- Handlers get one `&mut SagaContext`, no bean parameters (closures capture); `send`, `publish` and `schedule_*` return
  `Result`; capturing a `Sender` is forbidden by documentation, not by a startup check.
- A handler error is an `Err` or a caught panic; a synchronous handler also holds a tokio worker.
- Transactions are an explicit `Tx` from a `TxProvider` port; the in-memory ports exist behind the feature `testing`.
- Idempotency keys are `IdempotencyKey::Header` / `IdempotencyKey::From(fn)` instead of SpEL; a store failure before an
  adapter's body ran is `RetryableExternal` (Kotlin: a plain failure); a dropped adapter future leaves its record
  `IN_PROGRESS` until the lease, a panicking one is `FAILED`; an unbound `ExternalCallsHandle` fails at call time (Kotlin
  checks at startup).
- A partner translator is a closure returning `Result<Option<TranslatedEvent>, _>`; `InvalidMessage` skips the record at once.
- Configuration is `SNODRA_*` environment variables (milliseconds); partner sources and the webhook secret are set in code.
- Metrics are `SagaStats` counters and gauges (no Micrometer); the logging keys are a `tracing` span's fields.
- A deadline's `payloadType` is `std::any::type_name` of its payload (Kotlin: the `@MessageType` name or the FQCN).
- `SagaTestFixture` is in the crate behind a feature (Kotlin: `snodra-messaging-test`) and panics instead of throwing.

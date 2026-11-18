# Spring Boot

`snodra-messaging` is a Spring Boot starter, not a framework beside Boot. It uses Boot's
auto-configuration, its `@ConfigurationProperties` binding, its transaction managers and its Actuator,
so a Snodra service is an ordinary Boot application with a few annotations.

## Add it

```kotlin
dependencies {
    implementation("com.damoreira.snodra:snodra-messaging:0.5.0")
    implementation("com.damoreira.snodra:snodra-messaging-kafka:0.5.0")
    implementation("com.damoreira.snodra:snodra-messaging-mongo:0.5.0")
    testImplementation("com.damoreira.snodra:snodra-messaging-test:0.5.0")
}
```

Spring Boot 4 and Kotlin 2.4 are the supported line. The starter brings the buses, the hub client,
the outbox, the event processors and the saga runtime; the add-ons bring the stores, and the test
module brings the in-memory harness.

## What auto-configuration does

- Finds `@CommandHandler`, `@QueryHandler` and `@EventHandler` methods in the application's packages.
- Opens the hub stream, registers every handled type and reconnects with backoff.
- Creates the outbox relay, the event processors, the dead-letter handling and the saga runtime.
- Binds `snodra.messaging.*` and falls back to `SNODRA_*` environment variables.
- Masks tokens and secrets in Actuator's `configprops` and `env`.

A handler is a Spring bean. `@Transactional` handlers are plain (non-suspend) functions so the
transaction is bound to the thread; suspend handlers work outside a surrounding transaction. See
[Kotlin configuration](../messaging/kotlin/configuration.md) for the transaction rules.

## The handler surface

```kotlin
@Component
class Orders(private val events: EventBus) {
    @CommandHandler
    fun handle(command: PlaceOrder): PlaceOrderResult { /* ... */ }

    @QueryHandler
    fun handle(query: GetOrder): OrderView { /* ... */ }

    @EventHandler
    fun on(event: OrderPlaced) { /* ... */ }
}
```

`@RequiresAuthentication` on a handler evaluates a Spring Security expression against the forwarded
identity; realm roles become `ROLE_<role>`. That is the same identity a REST endpoint sees, which is
what makes a Boot service a natural edge.

## Actuator and observability

The service's Actuator endpoints keep working. Metrics go through Micrometer; set the OTLP endpoint
as you would for any Boot service. The Snodra instruments use the `snodra_*` names, so dashboards can
mix service and hub series.

## Read next

- [Kotlin quick start](../messaging/kotlin/quickstart.md) and [API](../messaging/kotlin/api.md).
- [Kotlin configuration](../messaging/kotlin/configuration.md), including security and retries.
- [OAuth2 provider](oauth2.md) for the identity provider side.
- [Monitoring](../operations/monitoring.md) for the metrics to expect.

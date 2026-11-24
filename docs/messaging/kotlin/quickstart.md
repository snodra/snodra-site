# Kotlin quick start

### Dependency

```kotlin
// settings.gradle.kts / build.gradle.kts
repositories {
    mavenCentral()
}

dependencies {
    implementation("com.damoreira.snodra:snodra-messaging:0.6.1")
    implementation("com.damoreira.snodra:snodra-messaging-kafka:0.6.1")   // or -rabbitmq
    implementation("com.damoreira.snodra:snodra-messaging-mongo:0.6.1")   // or -jdbc
    // a service's *-api module depends on the api artifact only:
    // api("com.damoreira.snodra:snodra-messaging-api:0.6.1")
    testImplementation("com.damoreira.snodra:snodra-messaging-test:0.6.1")
}
```

Every artifact is on Maven Central. The store add-ons are only needed when the service handles
events, runs sagas or publishes through the outbox; see [Add-ons](../../add-ons/index.md).

Kotlin version note: a project that applies `io.spring.dependency-management` must set the Kotlin version
in its build script, otherwise the Boot BOM pins the Kotlin compiler classpath to 2.3.x and `compileKotlin` fails with a
`getPluginClasspaths()` NullPointerException.

```kotlin
extra["kotlin.version"] = "2.4.21"   // the Kotlin version in your version catalog
```

### Handlers

```kotlin
@Component
class WorkoutHandlers(private val repo: WorkoutRepository, private val events: EventBus) {

    // @Transactional handlers are plain (non-suspend) functions: see "Transactions" below.
    @CommandHandler
    @Transactional
    fun handle(cmd: LogWorkout, ctx: MessageContext): LogWorkoutResult {
        val workout = repo.save(Workout.from(cmd, ownerId = ctx.userId))
        events.publishBlocking(WorkoutLogged(workout.id, workout.ownerId, workout.loggedAt), key = workout.id)
        return LogWorkoutResult(workout.id)
    }

    @QueryHandler
    suspend fun handle(q: GetWorkout): GetWorkoutResult =
        repo.findById(q.workoutId)?.toResult() ?: throw NotFoundException(q.workoutId)

    @EventHandler
    suspend fun on(e: FileDeleted) {
        repo.detachFile(e.fileId)
    }
}
```

`Workout`, `WorkoutRepository` and `NotFoundException` are illustrative service types, not library classes.

Messages are plain data classes implementing the marker interfaces from the api module:

```kotlin
@MessageType("workouts.LogWorkout")
data class LogWorkout(val name: String) : Command<LogWorkoutResult>
```

### Sending

```kotlin
val logged = commandBus.send(LogWorkout("legs"))                 // suspend
val loggedNow = commandBus.sendBlocking(LogWorkout("legs"))      // blocking, for MVC controllers
val workout = queryBus.send(GetWorkout(id))
eventBus.publish(WorkoutLogged(id, owner, at), key = id)         // inside the caller's message-store transaction

// Per call: priority, timeout (the total budget with retry), routing key, retry policy.
val urgent = commandBus.send(
    LogWorkout("legs"),
    SendOptions(priority = 10, timeout = Duration.ofSeconds(2), routingKey = id, retry = RetryPolicy(maxAttempts = 3)),
)
val quick = queryBus.sendBlocking(GetWorkout(id), SendOptions(retry = RetryPolicy.NONE)) // no retry for this call
```

## Next

- [Configuration](configuration.md) and the four [hub authentication modes](../../server/configuration/index.md).
- [API](api.md) for query modes, sagas and processors.

# Commands

A command is an imperative request that one service change something. `orders.PlaceOrder` and
`billing.LogWorkout` are commands. The name is the wire type; the server routes by it.

## The rules

| Property | Command |
|---|---|
| Handler count | exactly one live instance of one owning service |
| Path | sent over the hub, never through the event store |
| Return | one reply, or one error; multi-part answers are queries, not commands |
| Retry after `TIMEOUT` | never automatic: the handler may have run |
| Retry after `NO_HANDLER`, `RESOURCE_EXHAUSTED` | safe when the policy allows it; the handler did not run |
| Ordering | per routing key, while one instance handles it; no global order |

The server forwards a command only to an instance that registered its type. If no instance is live,
the sender gets `NO_HANDLER` immediately. If the instance disappears after the command was
forwarded, the sender gets `HANDLER_DISCONNECTED` and the outcome is unknown. The libraries' retry
policy reflects that distinction; see [Consistency](consistency.md).

## Write a handler

=== "Kotlin"

    ```kotlin
    @CommandHandler
    suspend fun handle(command: PlaceOrder): PlaceOrderResult {
        orders.place(command)
        events.publish(OrderPlaced(command.orderId))
        return PlaceOrderResult(command.orderId)
    }
    ```

=== "Rust"

    ```rust
    .command::<PlaceOrder, _, _>(|command, _ctx| async move {
        // write state, publish events, return the reply
        Ok(PlaceOrderResult { order_id: command.order_id })
    })
    ```

A command handler is also where an **idempotency key** belongs. A retried command with the same
aggregate id must not create a second order. Prefer a natural key inside the payload over
`Request.id`: the id changes on every retry by design.

## Where it is implemented

- Routing, deadlines and flow control: [Routing](../server/routing.md) and
  [Protocol](../server/protocol.md).
- Kotlin handlers and send options: [Kotlin API](../messaging/kotlin/api.md).
- Rust handlers and send options: [Rust API](../messaging/rust/api.md).
- Retry and timeout settings: [Server settings](../server/configuration/server.md) and
  [Tuning](../operations/tuning.md).

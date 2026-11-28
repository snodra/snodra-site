---
title: "Python quick start"
---

The Python library is pre-1.0 and at feature level 4 (0.8.0): the API may still change between minor versions. It
needs Python 3.12 or later.

## Dependencies

```sh
pip install snodra-messaging==0.8.0
pip install snodra-messaging-observability==0.8.0   # optional: OpenTelemetry

# One event store and one message store, when the service publishes or handles events:
pip install snodra-messaging-kafka==0.8.0           # Kafka event store
pip install snodra-messaging-rabbitmq==0.8.0        # RabbitMQ Streams event store
pip install snodra-messaging-mongo==0.8.0           # MongoDB message store
pip install snodra-messaging-sql==0.8.0             # SQL message store (PostgreSQL, MySQL)
```

The package is named `snodra`. The core package depends only on `grpcio`, `protobuf` and `cryptography`. Telemetry is a
separate package, `snodra-messaging-observability` (see [API](/docs/messaging/python/api/#telemetry)). Each add-on is a
package of its own and brings its store client; the core imports none of them.

## A service

A complete service that owns one command and one query. It is
[`examples/quickstart/src/orders_quickstart/service.py`](https://github.com/snodra/snodra-messaging-python/blob/main/examples/quickstart/src/orders_quickstart/service.py)
in the repository, and a test there runs it against a scripted hub.

```python
import asyncio
from dataclasses import dataclass

import snodra


# Messages are dataclasses (or Pydantic models). The wire name is declared once, on the class.
@dataclass
class Item:
    sku: str
    quantity: int


@snodra.message_type("orders.PlaceOrder")
@dataclass
class PlaceOrder:
    order_id: str  # "orderId" on the wire
    items: list[Item]


@dataclass
class OrderReceipt:  # a result has no wire name of its own
    order_id: str
    total: int


@snodra.message_type("orders.GetOrder")
@dataclass
class GetOrder:
    order_id: str


@dataclass
class Order:
    order_id: str
    status: str


@snodra.message_type("stock.CheckStock")
@dataclass
class CheckStock:
    items: list[Item]


@dataclass
class Stock:
    available: bool


def build(settings: snodra.Settings | None = None) -> snodra.App:
    if settings is None:
        settings = snodra.Settings.from_env(service="orders-service")
    app = snodra.App(settings)

    @app.command_handler
    async def place_order(cmd: PlaceOrder) -> OrderReceipt:
        # A request sent while a request is handled carries its correlation id, the caller's token and the trace on.
        stock = await app.query(CheckStock(items=cmd.items), Stock)
        if not stock.available:
            raise snodra.HandlerError("out of stock", details={"orderId": cmd.order_id})
        return OrderReceipt(order_id=cmd.order_id, total=42)

    @app.query_handler(guard=snodra.role("orders-user"))
    async def get_order(q: GetOrder) -> Order:
        _caller = snodra.current_caller()
        return Order(order_id=q.order_id, status="placed")

    return app


async def run(settings: snodra.Settings | None = None) -> None:
    app = build(settings)
    await app.run()


if __name__ == "__main__":
    asyncio.run(run())
```

A message is a dataclass (or Pydantic model) decorated with `@snodra.message_type("...")`, which declares the
protocol's wire type name; its payload is JSON by default. Handlers are registered before `start` (or `run`); a
registration error is raised when registered or checked during startup.

## Publish and handle an event

An event is a message type too. Build the service with one event store and one message store, then publish the event
inside the transaction that holds the service's own writes:

```python
from dataclasses import dataclass
import snodra
from snodra_kafka import KafkaConfig, KafkaEventStore
from snodra_sql import SqlConfig, SqlStore


@snodra.message_type("orders.OrderPlaced")
@dataclass
class OrderPlaced:
    order_id: str
    total: int


store = SqlStore(SqlConfig.from_env())             # the message store: outbox and processed-event markers
events = KafkaEventStore(KafkaConfig.from_env())   # the event store: where the relay publishes

settings = snodra.Settings.from_env(service="orders-service")
app = snodra.App(settings, store=store, event_store=events)
```

```python
# In a command handler: one transaction, the service's rows and the outbox entry.
async with store.transaction():
    # your own database writes here...
    await app.publish(OrderPlaced(order_id=cmd.order_id, total=cmd.total), key=cmd.order_id)
```

```python
# In the same service, or in any other one: the handler and its marker commit together.
@app.event_handler(processor="orders")
async def on_order_placed(event: OrderPlaced) -> None:
    await project_order(event)
```

The relay in every instance publishes what the outbox holds, at least once; a redelivered event finds its
`processor:orders:<eventId>` marker and is skipped. `key` is the order key: events with one key reach a processor in
publish order. A handler without `processor=` runs in the `default` processor. The pieces are in
[API](/docs/messaging/python/api/#events), the settings in
[Configuration](/docs/messaging/python/configuration/#events), and the stores in [Add-ons](/docs/add-ons/).

## Level 3: control, reset and dead letters

Level 3 needs nothing new in the service: the hub's dashboard and API drive the processor. A record that exhausts its
attempts is parked in the message store by default (`SNODRA_EVENTS_DEAD_LETTER_MODE=collection`), and the hub lists,
retries and discards it. A reset runs a handler you register first, then replays the range, skipping handlers declared
with `replay=False`:

```python
# Runs before any marker or position moves when a reset replays anything.
@app.reset_handler("orders")
async def clear_projection(reset: snodra.ResetContext) -> None:
    await reset_projection()   # rebuilt from the replay

# An effect outside the database is never replayed.
@app.event_handler(processor="orders", replay=False)
async def on_order_placed(event: OrderPlaced) -> None:
    await send_confirmation(event)
```

With the service registered, pause, reset and read the letters through the hub (the write credential is the hub's, see
[Processor control](/docs/server/processor-control/)):

```sh
WRITE_TOKEN=<the hub's write token>
HUB=http://localhost:7001/api/v1/services/orders-service/processors/orders
curl -s -X POST -H "Authorization: Bearer $WRITE_TOKEN" "$HUB/pause"
curl -s -X POST -H "Authorization: Bearer $WRITE_TOKEN" \
  -H 'Content-Type: application/json' -d '{"to":"earliest"}' "$HUB/reset"
curl -s -X POST -H "Authorization: Bearer $WRITE_TOKEN" "$HUB/dead-letters/retry-all"
```

A pause persists in the message store, and so do a reset's lock and replay ranges, so they reach every instance on its
next poll. A reset the hub does not finish (the hub died mid-way) is not carried on: its lease lapses and the
instances release it and consume again by themselves. The status, the control protocol and every outcome are in
[API](/docs/messaging/python/api/#processor-control) and
[Dead letters](/docs/messaging/python/api/#dead-letters).

## Level 4: a saga and an external call

A saga is a long-running process that remembers state between events. It runs in the `default` processor, after the
event handlers, and needs one event store and one message store even when the service has no event handler. Decorate a
class with `@app.saga`; its handlers record commands, events and deadlines on a `SagaContext`, and the relay sends them
after the transaction commits:

```python
@snodra.message_type("payments.ChargeCard")
@dataclass
class ChargeCard:
    order_id: str


@app.saga("orders")
class OrderSaga:
    order_id: str = ""
    payment_ref: str = ""
    step: str = ""

    @snodra.saga_start("order_id")
    async def placed(self, event: OrderPlaced, ctx: snodra.SagaContext) -> None:
        self.order_id = event.order_id
        self.payment_ref = f"pay-{event.order_id}"
        ctx.associate_with("payment_ref", self.payment_ref)
        ctx.send(ChargeCard(order_id=event.order_id), routing_key=event.order_id)
        ctx.schedule(15 * 60, "charge-timeout")

    @snodra.saga_event("payment_ref", end=True)
    async def charged(self, event: ChargeSucceeded, ctx: snodra.SagaContext) -> None:
        self.step = "charged"

    @snodra.saga_deadline("charge-timeout", end=True)
    async def timed_out(self, ctx: snodra.SagaContext) -> None:
        self.step = "timed-out"
        ctx.publish(OrderPaymentFailed(order_id=self.order_id), key=self.order_id)

    @snodra.saga_command_failed(end=True)
    async def failed(self, event: snodra.SagaCommandFailed, ctx: snodra.SagaContext) -> None:
        self.step = event.reason
        ctx.publish(OrderPaymentFailed(order_id=self.order_id, reason=event.reason),
                    key=self.order_id)
```

Every handler of a command a saga sends must be idempotent by `idempotency-key`: the relay sends at least once. The
external call itself belongs in an idempotent command handler, which records the call before its body runs:

```python
@app.idempotent_command_handler(external_idempotent=True)
async def charge_card(cmd: ChargeCard) -> ChargeReceipt:
    key = snodra.current_message().headers["idempotency-key"]
    try:
        return await gateway.charge(cmd.order_id, key)
    except GatewayUnavailable as error:
        raise snodra.Retryable(str(error)) from error       # nothing was charged
    except GatewayAmbiguous as error:
        raise snodra.UnknownOutcome(str(error)) from error   # it may have charged
```

The model, the six `SagaCommandFailed` reasons, the dispatch rules and the record lifecycle are in
[API](/docs/messaging/python/api/#sagas-and-deadlines) and
[API](/docs/messaging/python/api/#idempotent-external-calls); the fixed level-4 clocks are in
[Configuration](/docs/messaging/python/configuration/#sagas-deadlines-and-external-calls).

## Run it against a hub

The hub is the `snodra/snodra-server` image (see the [Hub quick start](/docs/server/quickstart/)). Start one, then
the service:

```sh
SNODRA_SERVER_ADDRESS=localhost:7000 \
SNODRA_JWKS_URL=http://localhost:8080/realms/orders/protocol/openid-connect/certs \
SNODRA_ISSUER=http://localhost:8080/realms/orders \
python -m orders_quickstart.service
```

`get_order` is guarded, so the service needs the issuer's keys; see
[Configuration](/docs/messaging/python/configuration/). Drop the `guard=` to try it without an identity provider.

`snodra.Settings.from_env()` reads the `SNODRA_*` variables the Rust and Go libraries read too (the Kotlin library is
configured with Spring properties instead); keyword arguments passed to `from_env()` win over the environment.
[Configuration](/docs/messaging/python/configuration/) lists them all.

A service that publishes or handles events also needs its event store and its message store: Kafka or RabbitMQ
Streams, and MongoDB or SQL. Their variables (`SNODRA_KAFKA_BOOTSTRAP`, `SNODRA_STORE_MONGO_URI`, `SNODRA_STORE_SQL_URL`, ...) are read by the
add-on's own `from_env()` and are listed in [Configuration](/docs/messaging/python/configuration/#add-ons).

## Next

- [API](/docs/messaging/python/api/): events, stores and processors, processor status and control, reset and replay,
  dead letters, sagas and deadlines, idempotent external calls, the other handlers, sending, the four query modes,
  errors, identity, lifecycle and telemetry.
- [Configuration](/docs/messaging/python/configuration/): every `SNODRA_*` variable of the core and of every add-on,
  and every credential.
- [Testing](/docs/messaging/python/testing/): testing handlers, the `snodra.testing` kits and the conformance runner.

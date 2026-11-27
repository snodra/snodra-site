---
title: "Python quick start"
---

The Python library is pre-1.0 and at feature level 2: the API may still change between minor versions. It needs Python
3.12 or later.

## Dependencies

```sh
pip install snodra-messaging
pip install snodra-messaging-observability   # optional: OpenTelemetry

# One event store and one message store, when the service publishes or handles events:
pip install snodra-messaging-kafka           # Kafka event store
pip install snodra-messaging-rabbitmq        # RabbitMQ Streams event store
pip install snodra-messaging-mongo           # MongoDB message store
pip install snodra-messaging-sql             # SQL message store (PostgreSQL, MySQL)
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
`processor:orders:<eventId>` marker and is skipped. `key` is the order key: events with one key reach a
processor in publish order. A handler without `processor=` runs in the `default` processor. The pieces are in
[API](/docs/messaging/python/api/#events), the settings in [Configuration](/docs/messaging/python/configuration/#events), and
the stores in [Add-ons](/docs/add-ons/).

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

- [API](/docs/messaging/python/api/): events, stores and processors, the other handlers, sending, the four query modes,
  errors, identity, lifecycle and telemetry.
- [Configuration](/docs/messaging/python/configuration/): every `SNODRA_*` variable of the core and of every add-on,
  and every credential.
- [Testing](/docs/messaging/python/testing/): testing handlers, the `snodra.testing` kits and the conformance runner.

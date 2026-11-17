# Hub quick start

The hub running in five minutes. You need Docker; a routed command needs a service as well.

## 1. Start the hub

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT= \
  gdamoreira/snodra-server:latest
```

- `7000` — gRPC, where services connect.
- `7001` — HTTP, for the dashboard and its API.
- `SNODRA_SERVER_OTLP_ENDPOINT=` disables trace export for this run.

## 2. Check health

```sh
curl -s localhost:7001/api/v1/version
```

```json
{"version": "1.0.0", "hubId": "hub-1", "startedAtMs": 1762250000000}
```

The image has no shell; it probes itself with `/app/snodra-server --health-check`, which is what the
`HEALTHCHECK` in the image runs.

## 3. Open the dashboard

<http://localhost:7001/ui/>

An empty topology is correct: the hub learns ownership from the connections. The dashboard shows
`0 instances` until a service registers.

## 4. Register a service

Any gRPC client can do it; the client libraries do it for you. In Kotlin, add the starter and
annotate a handler:

```kotlin
@CommandHandler
fun handle(command: PlaceOrder) { /* ... */ }
```

The starter opens `Hub.Connect`, sends `Register` with every handled type, and reconnects on its
own. The Rust crate does the same through one builder. See
[the Kotlin quick start](https://snodra-server.readthedocs.io/latest/messaging/kotlin/quickstart/) and
[the Rust quick start](https://snodra-server.readthedocs.io/latest/messaging/rust/quickstart/).

## 5. Send a first request

With the service registered, the request types it handles appear in the dashboard. A request is a
normal gRPC `Request` message on the same stream; the client library's `send_command` /
`send_query` is the supported way to build one.

```text
Request{ request_id, type: "orders.PlaceOrder", payload: {...}, timeout_ms: 5000 }
```

The hub forwards it to a live `orders` instance, enforces the deadline, and returns the handler's
`Reply` or an `Error` with a status code.

## Next

- [The four authentication modes](configuration/index.md) — start `permissive`, move to `enforce`.
- [Server settings](configuration/server.md) — timeouts, queues, dashboard, event browser.
- [The protocol](https://snodra-server.readthedocs.io/latest/hub/protocol/) — the whole message contract.

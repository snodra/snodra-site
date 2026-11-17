# Examples

Runnable starting points for the hub and its clients. Full reference: [the server pages](../server/index.md).

## Run the hub

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_OTLP_ENDPOINT= \
  snodra/snodra-server:latest
```

Or with Compose:

```yaml
services:
  snodra-server:
    image: snodra/snodra-server:latest
    ports: ["7000:7000", "7001:7001"]
    environment:
      SNODRA_SERVER_OTLP_ENDPOINT: ""
    healthcheck:
      test: ["CMD", "/app/snodra-server", "--health-check"]
```

Dashboard: <http://localhost:7001/ui/> · version: `curl -s localhost:7001/api/v1/version`

## Register a service

Any gRPC client opens `Hub.Connect`, sends `Register` with the types it handles and keeps the stream
open. The [Kotlin starter](../messaging/kotlin/quickstart.md) and the
[Rust crate](../messaging/rust/quickstart.md) do it for you.

```text
Register{ service_name: "orders", instance_id: "orders-1",
          commands: ["orders.PlaceOrder"], queries: [] }
```

## Send a request

```text
Request{ request_id: "r-1", type: "orders.PlaceOrder",
         payload: {"id":"o-1","item":"banner"}, timeout_ms: 5000 }
```

The hub routes it to a live `orders` instance and relays `Reply` or `Error`.

## Authentication

```sh
openssl rand -hex 32                       # the service's token
echo '<the token>' | docker run --rm -i --entrypoint /app/snodra-server \
  snodra/snodra-server:latest acl hash -  # its SHA-256 for the ACL

docker run --rm -p 7000:7000 -p 7001:7001 \
  -e SNODRA_SERVER_AUTH_MODE=permissive \
  -e SNODRA_SERVER_ACL_FILE=/etc/kraken/kraken.acl.toml \
  -v "$PWD/kraken.acl.toml:/etc/kraken/kraken.acl.toml:ro" \
  snodra/snodra-server:latest
```

Then follow [the authentication pages](../server/configuration/index.md).

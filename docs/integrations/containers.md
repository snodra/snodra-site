# Containers

The server ships as a distroless image with no shell. A service ships as your own image; it only needs
the library and the server address.

## The image

```sh
docker run --rm -p 7000:7000 -p 7001:7001 \
  snodra/snodra-server:0.6.0
```

| Port | Protocol | Use |
|---|---|---|
| `7000` | gRPC | services connect here |
| `7001` | HTTP | dashboard `/ui/`, API `/api/v1/` |

The image runs as a non-root user, declares both ports, and has a `HEALTHCHECK` that runs
`/app/snodra-server --health-check`. The probe calls `grpc.health.v1.Health/Check` on the configured
listen address within 3 seconds and exits `0` only when the status is `SERVING`. With TLS configured
it speaks TLS and pins the server's own certificate, so the probe needs no change.

## Compose

```yaml
services:
  snodra-server:
    image: snodra/snodra-server:0.6.0
    ports: ["7000:7000", "7001:7001"]
    environment:
      SNODRA_SERVER_OTLP_ENDPOINT: http://otel-lgtm:4317
    # The image already declares this healthcheck; repeat it only to change the timings.
    healthcheck:
      test: ["CMD", "/app/snodra-server", "--health-check"]
      interval: 10s
      timeout: 3s
      retries: 3

  orders:
    # A Rust service; a Kotlin service uses the equivalent snodra.messaging.* and
    # spring.mongodb.* keys.
    image: orders:dev
    environment:
      SNODRA_SERVICE_NAME: orders
      SNODRA_SERVER_ADDRESS: static://snodra-server:7000
      SNODRA_KAFKA_BOOTSTRAP: kafka:19092
      SNODRA_MONGODB_URI: mongodb://mongo:27017/orders?replicaSet=rs0
    depends_on:
      snodra-server:
        condition: service_healthy
```

A service that connects to more than one server uses a comma-separated address:
`static://snodra-server-1:7000,snodra-server-2:7000`.

## Kubernetes

The same image, with the binary's probe as an exec probe:

```yaml
containers:
  - name: snodra-server
    image: snodra/snodra-server:0.6.0
    ports:
      - { name: grpc, containerPort: 7000 }
      - { name: http, containerPort: 7001 }
    env:
      - { name: SNODRA_SERVER_OTLP_ENDPOINT, value: "http://otel-collector:4317" }
    readinessProbe:
      exec: { command: ["/app/snodra-server", "--health-check"] }
      periodSeconds: 10
      timeoutSeconds: 3
    livenessProbe:
      exec: { command: ["/app/snodra-server", "--health-check"] }
      periodSeconds: 20
      timeoutSeconds: 3
      failureThreshold: 3
```

Give the pod a stable `SNODRA_SERVER_ID` only if you need the same `instance` label across restarts;
by default it is the hostname plus a random suffix.

## Shutdown and secrets

`SIGTERM` sets health to `NOT_SERVING`, closes streams with `UNAVAILABLE` and drains for up to five
seconds. Docker's default 10-second grace period is enough for the server; a service with open
streams may need more. Use `stop_grace_period`/`terminationGracePeriodSeconds` if its handlers are
long.

Prefer `_FILE` settings for every secret: `SNODRA_SERVER_DASHBOARD_TOKEN_FILE`,
`SNODRA_MESSAGING_HUB_TOKEN_FILE`, `SNODRA_MESSAGING_HUB_OAUTH2_CLIENT_SECRET_FILE`,
`SNODRA_SERVER_OAUTH2_CLIENT_SECRET_FILE`, `SNODRA_RABBITMQ_PASSWORD_FILE`. An environment variable
shows in `docker inspect` and `/proc`.

## Read next

- Build and image internals: [Build and image](../server/build-and-image.md).
- Every server variable: [Server settings](../server/configuration/server.md).
- A multi-server setup: [Server operations](../server/operations.md).

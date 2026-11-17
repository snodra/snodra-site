# Integrations

Snodra connects to the tools you already run. These pages cover the common edges; the reference
pages carry the exact settings.

| Integration | What it gives you | Page |
|---|---|---|
| Spring Boot | A starter that is native to Boot: auto-configuration, annotations, Actuator | [Spring Boot](spring-boot.md) |
| Keycloak | OAuth2 client-credentials authentication with short-lived JWTs | [Keycloak](keycloak.md) |
| OpenTelemetry | OTLP metrics and traces from the server and the libraries | [OpenTelemetry](opentelemetry.md) |
| Docker Compose and Kubernetes | The image, ports, probes and graceful shutdown | [Containers](containers.md) |
| An existing service | Speak `snodra.hub.v1` directly, without a Snodra library | [Existing services](existing-service.md) |

## The common shape

Every service, whatever its language, does the same four things:

1. Opens one bidirectional `Hub.Connect` stream per instance.
2. Sends `Register` with its service name, instance id and the command and query types it handles.
3. Answers `Request` messages for those types and sends `Reply`.
4. Sends and receives events through an event store and a message store, or only the hub client if
   it has no events.

The libraries package that shape. An existing service can implement it directly; see
[Existing services](existing-service.md).

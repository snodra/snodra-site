# Operations

Running Snodra is running a stateless server, a set of client services and the stores they use. This
section is the operator's view: what to watch, how to test, how to tune, and how to upgrade.

| Task | Page | First question |
|---|---|---|
| Know whether it is healthy | [Monitoring](monitoring.md) | Are the server, the services and the stores up? |
| Prove a change works | [Testing](testing.md) | Does the handler, the store or the client pass its kit? |
| Handle load and deadlines | [Tuning](tuning.md) | Which queue, permit or timeout is the limit? |
| Move to a new release | [Upgrades](upgrades.md) | Is this a rolling restart or a coordinated window? |

## The operational surface

- **Server**: gRPC `7000`, HTTP `7001`, the dashboard at `/ui/`, the health service, JSON logs on
  stdout, OTLP metrics and traces, and the `--health-check` probe.
- **Services**: the library's hub-client and processor metrics, plus the service's own telemetry.
- **Stores**: the broker's lag and disk, the database's transactions, indexes and retention.
- **Tools**: the [dashboard](../server/dashboard.md) for the live view, the
  [event browser](../tools/event-browser.md) for what happened, and the
  [conformance runner](../tools/conformance-runner.md) for a client library.

## Backups and blast radius

The server keeps no state. Back up the message store (outbox, markers, sagas) and the event store's
retention policy, not the server. Losing a server loses only the in-memory registry: clients
reconnect and re-register. Losing the message store loses duplicate suppression and saga state;
losing the event store loses the events the broker has not retained.

The browser's operational detail is in [Server operations](../server/operations.md); the settings
behind it are in [Server settings](../server/configuration/server.md).

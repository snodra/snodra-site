# Conformance runner

`snodra-conformance` proves that a client library reaches **feature level 1**: that it can register,
handle and send, respect flow control and deadlines, survive a server restart, fail over between two
servers, and authenticate. It is how a new language binding is listed as supported.

## What it runs against

The runner starts **your conformance service** — a program built with your library's API that handles
the `conformance.*` types of the contract and reads its settings from `CONFORMANCE_*` variables. It
drives that service against:

- **fake servers inside the runner**, for the handshake, refusals, heartbeats, permits, credits,
  failover and credential checks;
- **real servers**, for the checks that need one. Without `--hub`, those checks are skipped.

Each instance runs in its own process group and is stopped with `SIGTERM` when its check ends. A
pre-flight check requires it to register on a fake server and stop within 5 seconds.

## Run it

```sh
# two servers, plain text, access control off
docker run -d --rm -p 7000:7000 -e SNODRA_SERVER_OTLP_ENDPOINT= snodra/snodra-server:0.5.0
docker run -d --rm -p 7100:7000 -e SNODRA_SERVER_OTLP_ENDPOINT= snodra/snodra-server:0.5.0

snodra-conformance run \
  --service-cmd "/path/to/your-conformance-service" \
  --service conformance-mylib \
  --hub 127.0.0.1:7000 --hub 127.0.0.1:7100 \
  --report text
```

`snodra-conformance list` prints the checks and what each needs. The runner, its reference service
and a deliberately broken service live in `snodra-conformance`; the image is published with every
release.

## Options

| Option | Meaning |
|---|---|
| `--service-cmd` | Starts one instance; no shell, with quoting and escapes |
| `--service-env` | `NAME=VALUE`, extra environment for every instance |
| `--service` | The service name, `conformance-<library>` |
| `--hub` | A real server, `host:port`; repeat it for the two-server check |
| `--only`, `--level` | A subset of checks, or the level to claim |
| `--report` | `text` or `json` |
| `--work-dir` | Where each instance's log goes |
| `--check-timeout`, `--startup-timeout` | Bounds of one check (180 s) and of a start (30 s) |

The exit code is `0` only when no check failed and none is unimplemented. A partial run does not
claim a level.

## Reading the report

One line per check id, the contract and runner versions, and whether the level was reached. Attach
the text report of a full run against the current server image when you ask for a library to be
listed.

## Read next

- The test kits you already have: [Testing](../operations/testing.md).
- The wire contract the checks exercise: [Protocol](../server/protocol.md).
- The Kotlin and Rust test pages: [Kotlin testing](../messaging/kotlin/testing.md) and
  [Rust testing](../messaging/rust/testing.md).

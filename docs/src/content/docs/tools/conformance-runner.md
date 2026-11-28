---
title: "Conformance runner"
---

`snodra-conformance` proves that a client library reaches **feature level 1**: that it can register,
handle and send, respect flow control and deadlines, survive a server restart, fail over between two
servers, and authenticate. It is how a new language binding is listed as supported.

## What it runs against

The runner starts **your conformance service** — a program built with your library's API that handles
the `conformance.*` types of the contract and reads its settings from `CONFORMANCE_*` variables. The service should
turn on its library's "always route through the hub" setting, so its sends to its own types go through the hub. It
drives that service against:

- **fake servers inside the runner**, for the handshake, refusals, heartbeats, permits, credits,
  failover and credential checks;
- **real servers**, for the checks that need one. Without `--hub`, those checks are skipped.

Each instance runs in its own process group and is stopped with `SIGTERM` when its check ends. A
pre-flight check requires it to register on a fake server and stop within 5 seconds.

## Run it

Two servers from the current release of the server image (see the [Hub quick start](/docs/server/quickstart/)),
then the runner:

```sh
# two servers, plain text, access control off
docker run -d --rm -p 7000:7000 -e SNODRA_SERVER_OTLP_ENDPOINT= -e SNODRA_SERVER_CATALOG=off snodra/snodra-server:latest
docker run -d --rm -p 7100:7000 -e SNODRA_SERVER_OTLP_ENDPOINT= -e SNODRA_SERVER_CATALOG=off snodra/snodra-server:latest

snodra-conformance run \
  --service-cmd "/path/to/your-conformance-service" \
  --service conformance-mylib \
  --hub 127.0.0.1:7000 --hub 127.0.0.1:7100 \
  --report text
```

`snodra-conformance list` prints the checks and what each needs. The runner, its reference service
and a deliberately broken service live in `snodra-conformance`; each release publishes
binaries for Linux and macOS (no Windows binary) on its
[releases page](https://github.com/snodra/snodra-conformance/releases) and the container image
`snodra/snodra-conformance`.

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

- Writing a conformance service, what the runner does not observe and how its fake servers differ:
  [Conformance](/docs/library-authors/conformance/).
- The test kits you already have: [Testing](/docs/operations/testing/).
- The wire contract the checks exercise: [Protocol](/docs/library-authors/protocol/).
- The library test pages: [Kotlin testing](/docs/messaging/kotlin/testing/),
  [Rust testing](/docs/messaging/rust/testing/), [Go testing](/docs/messaging/go/testing/) and [Python testing](/docs/messaging/python/testing/).

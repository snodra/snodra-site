# Conformance

This page is for library authors who want to prove the feature level their library claims. After reading it you know
what proves each level, how to run the conformance runner against your library, what its report means and how to
use it to get your library listed.

## What proves each level

- **Level 1** is proved by the conformance runner, `snodra-conformance`: a language-neutral binary that drives your
  library through a real hub and through fake hubs of its own, and checks every `L1-*` id of
  [feature-levels.md](feature-levels.md#level-1-core).
- **Levels 2 to 4** are proved by the event-store and message-store conformance kits that ship with both official
  libraries: every add-on runs them in its own tests
  ([event-store-add-ons.md](event-store-add-ons.md#the-conformance-kit),
  [message-store-add-ons.md](message-store-add-ons.md#the-conformance-kit)). A library in another language ports them.
  The checks of levels 2 to 4 marked "runner, not checked yet" in [feature-levels.md](feature-levels.md) are proved by
  the library's own tests until a later runner version checks them.

## The conformance service

Your library runs a small **conformance service** for the runner: it handles fixed `conformance.*` message types
(echo, fail, sleep, a stream, a subscription, a relay through the hub, and `conformance.Send`, which makes your
library send a request and report the outcome), written with your library's API as an application would write them.
The contract, with the JSON Schema of every type and how each check uses them, is
[the conformance contract](https://github.com/snodra/snodra-conformance/blob/main/docs/contract.md) (contract version 1). Two complete examples of about 800
lines each: the Rust reference service in the snodra-conformance repository (`reference-service/`), and the Kotlin
conformance service in the snodra-messaging repository (`examples/conformance-service`). Both pass every level-1 check,
and the runner's own mutation matrix proves that each check fails when it should.

The runner starts the service itself, once or more per check, with its configuration in `CONFORMANCE_*` environment
variables (the hubs, the service name and instance id, the capacity, the retry policy, credentials), so the service
is a program that reads them, maps them onto your library's configuration, registers its handlers and stops on
SIGTERM within 5 s.

## Running the runner

The runner lives in the snodra-conformance repository (`cargo build --release -p snodra-conformance`, the binary is
`target/release/snodra-conformance`) and ships as the `snodra/snodra-conformance` image; the [releases](https://github.com/snodra/snodra-conformance/releases) name the current version. Start one or two hubs
from the hub's image (plain text, access control off), then:

```sh
snodra-conformance run \
  --service-cmd "/path/to/your-conformance-service --some-flag" \
  --service conformance-mylib \
  --hub 127.0.0.1:7000 --hub 127.0.0.1:7100 \
  --report text
```

| Option | Meaning |
|---|---|
| `--service-cmd` | the command that starts one instance of your conformance service. No shell runs it: it is split into words at blanks, with `'...'` and `"..."` quoting and `\` escaping, and has no variables, globs or redirections (put those in a wrapper script) |
| `--service-env` | `NAME=VALUE`, more environment for every instance (repeatable) |
| `--service` | the service name the instances register, `conformance-<library>` |
| `--hub` | a real hub, `host:port`; without one the checks that need a real hub are skipped; twice for the two-hub part of `L1-HUBS` |
| `--level` | `1`, the level the runner checks |
| `--only` | some check ids, comma-separated: a partial run, which never claims a level |
| `--report` | `text` or `json` |
| `--work-dir` | where each instance's log is written (one file per instance, named after the check) |
| `--check-timeout`, `--startup-timeout` | the bound of one check (180 s) and of an instance's start (30 s; raise it for a slow start) |

Before any check, a pre-flight start must register on a fake hub and stop on SIGTERM within 5 s; otherwise the run
ends with exit code 2 and the instance's log. Each instance runs in a process group of its own, stopped with SIGTERM
(a kill 5 s later) when its check ends. The fake hubs and the runner's token issuer listen on `127.0.0.1`, so the
service runs on the runner's machine or in its container. The image is distroless and has no shell: run it with a
`--service-cmd` that names a program inside it (mount your service, or build an image `FROM` it), or copy
`/app/snodra-conformance` into an image that can run your service. `snodra-conformance list` prints the checks and what
each needs.

## Reading the report

One line per check id: `PASS` (what was proved, and what was not observable), `FAIL` (what was expected and what was
seen), `SKIPPED` (a capability of the run is missing: no real hub given, or your library has no retry policy for
`L1-RETRY`) or `NOT IMPLEMENTED` (a check this runner version does not run). Text a service controls (error
messages, logs) is escaped, so it cannot write report lines. The report states the contract version and the runner
version, and ends with one verdict about the level:

| Verdict | When | Exit code |
|---|---|---|
| level 1 reached | every check of level 1 ran and passed | 0 |
| level 1 not proved: skipped ... | no check failed, some were skipped | 0 |
| level 1 not reached: failed ..., not implemented ... | a check failed or is not implemented | 1 |
| partial run: no level claimed | `--only` | 0, or 1 when a check failed |

The JSON report has the same content (`checks`, `partial`, `passed`, `complete`, `level_reached`).

## What the runner checks

Contract version 1: every level-1 check, each as
[the conformance contract](https://github.com/snodra/snodra-conformance/blob/main/docs/contract.md#how-each-check-is-proved) describes, none of levels 2 to 4. Some
parts of the level-1 rules cannot be observed from outside a library, and stay with its own tests:

- `L1-HANDSHAKE-ACK`: never waiting on the ack of a later `Register` (the conformance service registers no handler after
  start).
- `L1-NEVER-SENT` and `L1-HUB-FAILOVER`: a request still in the library's own outbound buffer when its stream breaks
  (reported as never sent, and moved to another hub with the same id); nothing outside the library can hold a request
  there deterministically.
- `L1-TOKEN`: never logging the token.
- `L1-TOKEN`, `L1-JWT`, `L1-MTLS`, `L1-TLS`: they are proved on the frames and the TLS handshakes the runner's fake hubs
  see, not against snodra-server's access control in mode `enforce`.
- `L1-PROPAGATION` for events is level 2.

## How the runner's hub differs from snodra-server

The fake hubs behave as snodra-server where a check relies on them: the handshake and its refusals (`FAILED_PRECONDITION`
for a first frame that is not a `Register`, `INVALID_ARGUMENT` for an empty identity, no permits, the reserved service name `snodra-server` or an instance id
starting with `snodra-server/`), the ack before
any echo, the 3 s / 10 s / 5 s / 60 s defaults of the ack, forwarding within the library's permits (queueing the rest,
honouring `Permits.grant`), later and empty `Register`s, `NO_HANDLER` for a type nobody serves, `INVALID_REQUEST` for a
request without an id, kind or type, and no `Cancel` for a command. The runner's tests run one script of frames
against a fake hub and against snodra-server and require the same answers. What remains different, on purpose:

- A fake hub routes nothing between instances: it is the only other party. It forwards what a check sends, including
  requests snodra-server would not route (a type the instance does not list, a unary request to a streaming handler), and
  answers the library's own requests as the check scripts them, including parts with a gap and ends with a wrong count.
- It acknowledges late or never, and echoes heartbeats before the ack, only where a check asks for it
  (`L1-HANDSHAKE-ACK`, `L1-EARLY-REQUESTS`, `L1-NEVER-SENT`).
- It evicts nobody and has no handshake deadline, no queue bounds, priorities or deadlines of its own, and no hub-side
  timeouts: a `TIMEOUT` or a close comes only when a check scripts it.
- It has no access control and no topology: credentials are recorded, never judged; TLS and mutual TLS use the
  runner's own CA, without the hub's check of the certificate's service name.
- It records `InstanceStatus` without snodra-server's bounds.

## Getting listed

Attach the text report of a full run (no `--only`) against the current hub image to the request that lists your
library ([index.md, Add your library](index.md#add-your-library)): the report names the runner version, the contract
version and every check's verdict, so a reader sees whether the level is reached and which checks were skipped.

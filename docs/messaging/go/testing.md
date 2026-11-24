# Testing

## Testing your handlers

A handler is a plain function, `func(context.Context, C) (R, error)`, so a service tests it as one: call the function
with a context and a message and check the result and the error. Keep the function apart from the registration (a named
function or a method, passed to `HandleCommand`) so that a test can reach it.

The library's own scripted hub, `internal/fakehub`, is an internal package: Go does not let another module import it.
A service does not need it. To test the wiring against a real hub, run the hub image (`snodra/snodra-server`, see the
[Hub quick start](../../server/quickstart.md)) and point the service at it with `SNODRA_SERVER_ADDRESS`.

## The library's own tests

The library's unit tests need no Docker and run against an in-process scripted hub, in the core module and in `observability/`:

```sh
go test -race ./...
```

## The conformance runner

The language-neutral [conformance runner](../../tools/conformance-runner.md) proves feature level 1. The library ships
its service for it, `examples/conformance-service`, written on the public API only; the runner drives it against
scripted hubs and a real one. `scripts/conformance.sh` in the repository runs the whole thing, and needs Docker:

```sh
scripts/conformance.sh                       # the 33 level-1 checks, a hub from the snodra/snodra-server image
scripts/conformance.sh --only L1-RETRY       # one check
SNODRA_HUB_PORT=17000 scripts/conformance.sh # when port 7000 is taken (the second hub is 100 above)
```

The script builds the service, downloads the pinned runner release into `bin/` and checks it against the sha256 pinned
in `scripts/conformance-runner.sha256` (or uses the runner that `SNODRA_CONFORMANCE_BIN` names), starts the hub
(`SNODRA_SERVER_VERSION` picks the image tag) and removes it afterwards. On macOS the AirPlay Receiver holds port 7000,
so set `SNODRA_HUB_PORT` there. CI runs the same script with the same pinned runner, fails when a check fails or is
skipped, and keeps the runner's report as a build artifact.

The checks and what each asserts are listed in [Feature levels](../../library-authors/feature-levels.md) and in
[Conformance](../../library-authors/conformance.md).

## Level 2 to 4

The Go library has no event store, message store or saga add-ons, so there are no kits to run for it yet.

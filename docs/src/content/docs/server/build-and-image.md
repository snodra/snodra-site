---
title: "Build and image"
---

Build from source, run the container and pull the published image.

## Build and test

Requires Rust 1.99.1 (`rust-toolchain.toml` pins it), `protoc` and `cmake` (librdkafka is built from source for the
[event browser](/docs/server/event-browser/)). The event browser's tests (`tests/event_browser.rs`, one test in `src/http.rs` and
one in `tests/dashboard_ui.rs`) start a Kafka Testcontainer, so `cargo test` needs Docker.

```sh
cargo build
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

Unit tests live next to the code in `src/`; integration tests in `tests/` start a real hub on an
ephemeral port and drive it over gRPC (and over HTTP, with Kafka in a container for the event browser).

## Image

```sh
docker build -t snodra-server:dev .
docker run --rm -p 7000:7000 -p 7001:7001 -e SNODRA_SERVER_OTLP_ENDPOINT= snodra-server:dev
```

The builder installs `cmake` and `protobuf-compiler`; librdkafka and zlib are linked into the binary, so the runtime
stays distroless (no shell, no curl, no extra library). Its `HEALTHCHECK` runs the binary's own probe:
`HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["/app/snodra-server", "--health-check"]`.
In compose, `depends_on` can wait for it:

```yaml
services:
  snodra-server:
    image: snodra-server:dev
    environment:
      SNODRA_SERVER_OTLP_ENDPOINT: http://otel-lgtm:4317
    # The image already declares this healthcheck; repeat it only to change the timings.
    healthcheck:
      test: ["CMD", "/app/snodra-server", "--health-check"]
      interval: 10s
      timeout: 3s
      retries: 3
  orders:
    depends_on:
      snodra-server:
        condition: service_healthy
```

`docker stop` sends SIGTERM to the hub (PID 1), which shuts down gracefully (see above).

`snodra-server:dev` is the image name the Kotlin starter's integration tests use. CI publishes tagged
releases (`<version>`) to `snodra/snodra-server:<tag>` and `:latest`.

## Image build notes

```text
snodra-server/
├── Cargo.toml            # bin "snodra-server"; deps tonic, prost, tokio, tracing, opentelemetry, snodra-messaging (codec feature only)
├── build.rs              # tonic-build over protocol/hub.proto (git submodule at ./protocol)
├── protocol/             # git submodule: the server's proto
├── src/
│   ├── main.rs           # config, telemetry init, server start
│   ├── config.rs         # SNODRA_SERVER_* settings, effective request timeout
│   ├── context.rs        # ContextId (always "default")
│   ├── protocol.rs       # the RegisterAck, a Debug for credentials that never prints them
│   ├── registry.rs       # types, services, ring
│   ├── session.rs        # one task per Connect stream
│   ├── router.rs         # request forwarding, pending map, deadlines
│   ├── topology.rs       # topology snapshot shared by the RPC, the HTTP endpoint and the CLI
│   ├── edges.rs          # edge statistics per (sender service, type): window, latency sketch, cap
│   ├── http.rs           # the HTTP port: /api/v1 (JSON, the summary stream, the processor controls, the event browser), headers
│   ├── browser.rs        # the event browser's Kafka reads (rdkafka): search, record, tail, consumer groups
│   ├── events.rs         # the event browser's rules: filters, cursor, newest-first merge, record views, payload access
│   ├── api.rs            # dashboard API views (types, graph, settings, version, summary)
│   ├── assets.rs         # ui/ embedded with rust-embed, build id, caching
│   ├── cli.rs            # --health-check, --topology and `acl hash` modes
│   ├── auth.rs           # modes, ACL parsing and lookup, register and request checks, constant-time compare
│   ├── reload.rs         # mtime polling and SIGHUP for the ACL and the TLS pairs
│   ├── tls.rs            # rustls listeners, reloadable certificate, the client CA store (mTLS)
│   ├── mtls.rs           # the service a client certificate names (snodra://service/<name>), notAfter, fingerprint
│   ├── client.rs         # TLS client side of the probes (--tls-ca, pinned local certificate)
│   └── telemetry.rs
├── ui/                   # the dashboard: index.html, app.css, plain JavaScript modules, no third-party code
├── tests/                # integration tests over a real tonic server (connect.rs, topology.rs, http.rs, dashboard_api.rs, dashboard_ui.rs, cli.rs, auth.rs, tls.rs, dashboard_auth.rs among them); event_browser.rs against a Kafka Testcontainer
├── scripts/check-proto-sync.sh   # SHA-256 of proto/hub.proto against the published server's proto
└── Dockerfile
```

Dockerfile shape:

```dockerfile
# syntax=docker/dockerfile:1
FROM rust:1.99-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends cmake protobuf-compiler \
    libcurl4-openssl-dev libssl-dev zlib1g-dev libsasl2-dev libzstd-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Cargo.toml Cargo.lock build.rs ./
COPY proto ./proto
COPY src ./src
COPY ui ./ui
RUN cargo build --release --locked

FROM gcr.io/distroless/cc-debian12:nonroot
WORKDIR /app
COPY --from=builder /app/target/release/snodra-server /app/snodra-server
EXPOSE 7000 7001
USER nonroot
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 CMD ["/app/snodra-server", "--health-check"]
ENTRYPOINT ["/app/snodra-server"]
```

The generated Rust client is produced with `build_transport(false)`; clients build the stub with
`HubClient::new(channel)`. The local image name used by the Kotlin starter's integration tests is
`snodra-server:dev`.

Image name: `snodra/snodra-server:<version>` (placeholder host). Compose
runs it with `restart: unless-stopped` and a gRPC healthcheck.

---
title: "Go quick start"
---

The Go library is pre-1.0 and at feature level 1: the API may still change between minor versions. It needs Go 1.26
or later.

## Dependency

```sh
go get github.com/snodra/snodra-messaging-go@latest
go get github.com/snodra/snodra-messaging-go/observability@latest   # optional: OpenTelemetry
```

The package is named `snodra`; the examples import it as `snodra "github.com/snodra/snodra-messaging-go"`.
The core module depends only on gRPC and protobuf. Telemetry is a separate module,
`github.com/snodra/snodra-messaging-go/observability` (see [API](/docs/messaging/go/api/#telemetry)).

## A service

A complete service that owns one command and one query. It is
[`examples/quickstart/main.go`](https://github.com/snodra/snodra-messaging-go/blob/main/examples/quickstart/main.go)
in the repository, and a test there runs it against a scripted hub.

```go
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"sync"
	"syscall"

	snodra "github.com/snodra/snodra-messaging-go"
)

// PlaceOrder is a command: the orders-service owns it.
type PlaceOrder struct {
	OrderID string `json:"orderId"`
	Cents   int64  `json:"cents"`
}

func (PlaceOrder) MessageType() string { return "orders.PlaceOrder" }

// Receipt answers PlaceOrder.
type Receipt struct {
	OrderID string `json:"orderId"`
	Total   int64  `json:"total"`
}

// GetOrder is a query.
type GetOrder struct {
	OrderID string `json:"orderId"`
}

func (GetOrder) MessageType() string { return "orders.GetOrder" }

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// SNODRA_SERVICE_NAME, SNODRA_SERVER_ADDRESS and the other SNODRA_* variables override
	// the name given here.
	if err := run(ctx, snodra.FromEnv()); err != nil {
		log.Fatal(err)
	}
}

func run(ctx context.Context, opts ...snodra.Option) error {
	app, err := snodra.New(append([]snodra.Option{snodra.Service("orders-service")}, opts...)...)
	if err != nil {
		return err
	}

	var mu sync.Mutex
	orders := map[string]Receipt{}

	err = snodra.HandleCommand(app, func(ctx context.Context, cmd PlaceOrder) (Receipt, error) {
		if cmd.OrderID == "" {
			return Receipt{}, snodra.InvalidRequest("orderId is required")
		}
		mu.Lock()
		defer mu.Unlock()
		orders[cmd.OrderID] = Receipt{OrderID: cmd.OrderID, Total: cmd.Cents}
		return orders[cmd.OrderID], nil
	})
	if err != nil {
		return err
	}
	err = snodra.HandleQuery(app, func(ctx context.Context, q GetOrder) (Receipt, error) {
		mu.Lock()
		defer mu.Unlock()
		order, ok := orders[q.OrderID]
		if !ok {
			return Receipt{}, snodra.InvalidRequest("no such order")
		}
		return order, nil
	})
	if err != nil {
		return err
	}

	// Run connects to every hub, serves until ctx ends, then shuts down in order.
	return app.Run(ctx)
}
```

A message is a Go type with a `MessageType() string` method, which returns the protocol's type name; its payload is
JSON by default. Handlers are registered before `Start` (or `Run`); a registration error is returned at once and
again by `Start`.

## Run it against a hub

The hub is the `snodra/snodra-server` image (see the [Hub quick start](/docs/server/quickstart/)). Start one, then
the service:

```sh
SNODRA_SERVER_ADDRESS=localhost:7000 go run ./examples/quickstart
```

`snodra.FromEnv()` reads the `SNODRA_*` variables the Rust library reads too (the Kotlin library is configured with
Spring properties instead); options given after it win. [Configuration](/docs/messaging/go/configuration/) lists them all.

## Next

- [API](/docs/messaging/go/api/): the other handlers, sending, the four query modes, errors, identity, lifecycle and telemetry.
- [Testing](/docs/messaging/go/testing/): testing handlers and running the conformance runner.

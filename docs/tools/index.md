# Tools

Two optional tools make a deployment observable and a client library verifiable. Neither is needed
to run commands, queries or events.

| Tool | Answers | Page |
|---|---|---|
| **Event browser** | What events are in the store, what one record says, and how far behind a consumer group is | [Event browser](event-browser.md) |
| **Conformance runner** | Does this client library implement the contract, including failover and credentials? | [Conformance runner](conformance-runner.md) |

The browser is an operator's window into the event store; the runner is a library author's test
harness. Both are open source and ship as separate images or binaries.

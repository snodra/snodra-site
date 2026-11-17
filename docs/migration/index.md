# Migration

Two kinds of migration matter: the rename from `kraken` to `snodra`, and the compatibility rules that
make a version move predictable.

| Page | Answers |
|---|---|
| [From kraken](from-kraken.md) | Which names, packages, settings and metrics change, and which data does not |
| [Compatibility](compatibility.md) | What `snodra.hub.v1` guarantees and what it deliberately does not |
| [Upgrades](../operations/upgrades.md) | How to roll a release through a running deployment |

The short version: the data and the message shapes do not change. The identity does — repository
names, images, Java packages, Maven coordinates, Rust crate names, settings, metrics and the gRPC
package. Because the gRPC package changed, the server and every client move in one window.

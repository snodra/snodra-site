# Snodra documentation

The source of <https://snodra-server.readthedocs.io/latest/>: the hub, its Kotlin and Rust client
libraries, and runnable examples.

## Local preview

```sh
python3 -m venv .venv-docs
.venv-docs/bin/pip install -r docs/requirements.lock
make docs-serve
```

`make docs-build` runs the strict build; it is the same gate Read the Docs applies.

## Publishing

Read the Docs builds this repository; `.github/workflows/docs.yml` triggers a build on `main` and
creates a version for each `v*` tag. Add the Read the Docs API token as the
`READTHEDOCS_TOKEN` repository secret. The site configuration is `.readthedocs.yaml`; the
navigation is `mkdocs.yml`.

## Related repositories

- [`snodra-server`](https://github.com/gdamoreira/snodra-server) — the router.
- `snodra-messaging` and `snodra-messaging-rs` — the client libraries (private until v1.0.0).

## License

[MIT](LICENSE) © 2026 Guilherme D'Amoreira.

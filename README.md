# Snodra documentation

The source of <https://snodra.damoreira.com/>: the server, its Kotlin and Rust client libraries, and
runnable examples. Built with Material for MkDocs and served by GitHub Pages.

## Local preview

```sh
python3 -m venv .venv-docs
.venv-docs/bin/pip install -r docs/requirements.lock
make docs-serve
```

`make docs-build` runs the strict build, the same gate the workflow applies.

## Publishing

`.github/workflows/pages.yml` builds the site on every push and pull request and deploys it to GitHub
Pages from `main`. `docs/CNAME` sets the custom domain; in Cloudflare `snodra` is a `CNAME` to
`snodra.github.io` with the proxy off (Pages terminates TLS itself). Pull requests build only.

## Related repositories

- [`snodra-server`](https://github.com/snodra/snodra-server) — the router and its dashboard.
- [`snodra-messaging`](https://github.com/snodra/snodra-messaging) — the Kotlin library, on Maven Central.
- [`snodra-messaging-rs`](https://github.com/snodra/snodra-messaging-rs) — the Rust library, on crates.io.
- [`snodra-event-browser`](https://github.com/snodra/snodra-event-browser) and
  [`snodra-conformance`](https://github.com/snodra/snodra-conformance).

## License

[MIT](LICENSE) © 2026 Guilherme D'Amoreira.

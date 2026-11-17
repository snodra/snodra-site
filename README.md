<p align="center">
  <img alt="Snodra mascot" src="docs/assets/brand/svg/snodra.svg" width="160">
</p>

<h1 align="center">Snodra Documentation</h1>

<p align="center">
  The documentation portal of the Snodra suite: concepts, installation, the server reference, both client libraries, the add-ons, operations and integrations.
</p>

<p align="center">
  <a href="https://github.com/snodra/snodra-site/actions/workflows/pages.yml"><img alt="pages" src="https://github.com/snodra/snodra-site/actions/workflows/pages.yml/badge.svg"></a>
  <a href="https://snodra.damoreira.com/"><img alt="site" src="https://img.shields.io/badge/site-snodra.damoreira.com-0B5FFF"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-blue"></a>
</p>

---

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

[Apache-2.0](LICENSE) © 2026 Guilherme D'Amoreira.

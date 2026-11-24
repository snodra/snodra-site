<p align="center">
  <img alt="Snodra mascot" src="docs/assets/brand/svg/snodra.svg" width="160">
</p>

<h1 align="center">Snodra Site</h1>

<p align="center">
  The public face of the Snodra suite: the product landing page at the root and the documentation under
  <code>/docs/</code>.
</p>

<p align="center">
  <a href="https://github.com/snodra/snodra-site/actions/workflows/pages.yml"><img alt="pages" src="https://github.com/snodra/snodra-site/actions/workflows/pages.yml/badge.svg"></a>
  <a href="https://snodra.damoreira.com/"><img alt="landing" src="https://img.shields.io/badge/site-snodra.damoreira.com-0B5FFF"></a>
  <a href="https://snodra.damoreira.com/docs/"><img alt="docs" src="https://img.shields.io/badge/docs-snodra.damoreira.com-2DD4BF"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-blue"></a>
</p>

---

## Layout

| Path | What it is |
|---|---|
| `landing/` | The product landing page: Astro 7, Tailwind CSS 4 and a small motion layer. Static output in `landing/dist/`. |
| `docs/` | The documentation source for MkDocs Material. Built to `site/`. |
| `Makefile` | `make site` assembles the published artifact: the landing at `/`, the docs under `/docs/`. |
| `.github/workflows/pages.yml` | Builds both on every push and pull request, deploys `_site/` to GitHub Pages from `main`. |

## Local preview

### Landing

```sh
cd landing
npm install
npm run dev
```

The landing is a static Astro site. `npm run build` writes `landing/dist/`; `npm run preview` serves the
built output.

### Documentation

```sh
python3 -m venv .venv-docs
.venv-docs/bin/pip install -r docs/requirements.lock
make docs-serve
```

`make docs-build` runs the strict build, the same gate the workflow applies.

### The combined site

```sh
make landing-install
make site
python3 -m http.server 4321 --directory _site
```

Open <http://localhost:4321/> for the landing and <http://localhost:4321/docs/> for the documentation.

## Editing the landing

- `landing/src/pages/index.astro` composes the sections; each section is a component in
  `landing/src/components/`.
- `landing/src/data/releases.ts` is the release list used by the landing's changelog teaser and the
  `/changelog/` page. Update it when a component is tagged; the GitHub release notes remain the source of
  truth.
- `landing/src/styles/global.css` holds the design tokens, utilities and keyframes.
- `landing/src/scripts/motion.ts` holds the header, reveal, tab, copy and pointer effects. Everything
  respects `prefers-reduced-motion`.

## Publishing

`.github/workflows/pages.yml` builds the landing and the documentation on every push and pull request,
assembles `_site/`, and deploys it from `main`. `landing/public/CNAME` sets the custom domain at the
artifact root; in Cloudflare `snodra` is a `CNAME` to `snodra.github.io` with the proxy off (Pages
terminates TLS itself). Pull requests build only.

The documentation lives at `/docs/`; the root is the landing page. An old documentation URL such as
`/server/` lands on the 404 page, which forwards known documentation sections to `/docs/`.

## Related repositories

- [`snodra-server`](https://github.com/snodra/snodra-server) — the router and its dashboard.
- [`snodra-messaging`](https://github.com/snodra/snodra-messaging) — the Kotlin library, on Maven Central.
- [`snodra-messaging-rs`](https://github.com/snodra/snodra-messaging-rs) — the Rust library, on crates.io.
- [`snodra-event-browser`](https://github.com/snodra/snodra-event-browser) and
  [`snodra-conformance`](https://github.com/snodra/snodra-conformance).
- [`snodra-messaging-python`](https://github.com/snodra/snodra-messaging-python) and
  [`snodra-messaging-go`](https://github.com/snodra/snodra-messaging-go) — the next clients.

## License

[Apache-2.0](LICENSE) © 2026 Guilherme D'Amoreira.

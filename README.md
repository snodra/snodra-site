<p align="center">
  <img alt="Snodra mascot" src="landing/public/brand/snodra.svg" width="160">
</p>

<h1 align="center">Snodra Site</h1>

<p align="center">
  The public face of the Snodra suite: the product landing page at the root and the Starlight documentation under
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
| `docs/` | The documentation: Astro 7 with Starlight, Pagefind search and Mermaid diagrams. Static output in `docs/dist/`. |
| `Makefile` | `make site` assembles the published artifact: the landing at `/`, the docs under `/docs/`. |
| `.github/workflows/pages.yml` | Builds both on every push and pull request, deploys `_site/` to GitHub Pages from `main`. |

The documentation used to run on MkDocs Material. It now runs on Starlight; the old MkDocs and Read the Docs
configuration is gone.

## Local preview

### Landing

```sh
cd landing
npm install
npm run dev
```

The landing is a static Astro site. `npm run build` writes `landing/dist/`; `npm run preview` serves the built
output.

### Documentation

```sh
cd docs
npm install
npm run dev
```

Starlight serves the docs under <http://localhost:4321/docs/>. `npm run build` writes `docs/dist/`; the build
also generates the Pagefind search index and the sitemap.

### The combined site

```sh
make landing-install
make docs-install
make site
python3 -m http.server 4321 --directory _site
```

Open <http://localhost:4321/> for the landing and <http://localhost:4321/docs/> for the documentation.

## Editing the landing

- `landing/src/pages/index.astro` composes the sections; each section is a component in
  `landing/src/components/`.
- `landing/src/data/releases.ts` is the release list used by the landing's changelog teaser and the
  `/changelog/` page. Update it when a component is tagged; the GitHub release notes remain the source of truth.
- `landing/src/styles/global.css` holds the design tokens, utilities and keyframes.
- `landing/src/scripts/motion.ts` holds the header, reveal, tab, copy and pointer effects. Everything
  respects `prefers-reduced-motion`.

## Editing the documentation

- Content lives in `docs/src/content/docs/`, one Markdown or MDX file per page. The URL is
  `/docs/<path>/`; `index.md` is the directory page.
- Each page starts with frontmatter `title`; Starlight renders it as the page heading. Do not add a second
  H1 in the body.
- `docs/src/sidebar.mjs` is the sidebar. It mirrors the old MkDocs navigation; update it when a page is added,
  removed or moved.
- `docs/src/styles/theme.css` holds the brand accents and the small layout adjustments on top of Starlight.
- Use MDX only where a component is needed: `Tabs`/`TabItem` for the Kotlin/Rust/Go alternatives, or
  `CardGrid`/`LinkCard` for navigation cards.
- Images and downloadable files live in `docs/public/`; reference them as `/docs/...` so the base path stays
  correct.
- Mermaid diagrams stay in fenced `mermaid` blocks; the `astro-mermaid` integration renders them in the
  browser and follows the light/dark theme.

## Publishing

`.github/workflows/pages.yml` builds the landing and the Starlight documentation on every push and pull
request, assembles `_site/`, and deploys it from `main`. `landing/public/CNAME` sets the custom domain at the
artifact root; in Cloudflare `snodra` is a `CNAME` to `snodra.github.io` with the proxy off (Pages terminates
TLS itself). Pull requests build only.

The documentation lives at `/docs/`; the root is the landing page. An old documentation URL such as `/server/`
lands on the 404 page, which forwards known documentation sections to `/docs/`.

## Related repositories

- [`snodra-server`](https://github.com/snodra/snodra-server) — the router and its dashboard.
- [`snodra-messaging`](https://github.com/snodra/snodra-messaging) — the Kotlin library, on Maven Central.
- [`snodra-messaging-rs`](https://github.com/snodra/snodra-messaging-rs) — the Rust library, on crates.io.
- [`snodra-messaging-go`](https://github.com/snodra/snodra-messaging-go) — the Go library.
- [`snodra-event-browser`](https://github.com/snodra/snodra-event-browser) and
  [`snodra-conformance`](https://github.com/snodra/snodra-conformance).
- [`snodra-messaging-python`](https://github.com/snodra/snodra-messaging-python) — the next client.

## License

[Apache-2.0](LICENSE) © 2026 Guilherme D'Amoreira.

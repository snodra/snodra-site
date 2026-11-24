# Contributing

Documentation changes are welcome as pull requests against `main`.

- Branch from `main`: `docs/<topic>`.
- Conventional commits (`docs: …`).
- `cd docs && npm run build` must pass; it also checks the Pagefind index and the sitemap.
- English, present tense, second person. Code spans for paths and variables.
- Internal links use the `/docs/...` routes, not relative `.md` paths.
- Use MDX only when a Starlight component is needed (`Tabs`, `CardGrid`, `LinkCard`); plain Markdown otherwise.
- No internal hostnames, tokens or private endpoints.

By contributing you agree that your contribution is licensed under the Apache License 2.0.

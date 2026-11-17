PY := .venv-docs/bin/python
MKDOCS := .venv-docs/bin/mkdocs

.PHONY: docs-serve docs-build

docs-serve:
	$(MKDOCS) serve

docs-build:
	$(MKDOCS) build --strict

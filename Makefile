PY := .venv-docs/bin/python
MKDOCS := .venv-docs/bin/mkdocs

.PHONY: docs-serve docs-build docs-check

docs-serve:
	$(MKDOCS) serve

docs-build:
	$(MKDOCS) build --strict

docs-check:
	bash scripts/check-library-spec.sh

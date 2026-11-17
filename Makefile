PY := .venv-docs/bin/python
MKDOCS := .venv-docs/bin/mkdocs

.PHONY: docs-serve docs-build docs-publish

docs-serve:
	$(MKDOCS) serve

docs-build:
	$(MKDOCS) build --strict

docs-publish:
	$(MKDOCS) build --strict
	READTHEDOCS_TOKEN=$${READTHEDOCS_TOKEN:?set READTHEDOCS_TOKEN} .venv-docs/bin/readthedocs upload --project-slug kraken-hub --html site --version-name $${VERSION:-latest} --version-type branch

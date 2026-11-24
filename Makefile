PY := .venv-docs/bin/python
MKDOCS := .venv-docs/bin/mkdocs
NPM := npm
LANDING := landing
SITE := _site

.PHONY: docs-serve docs-build landing-install landing-dev landing-build site

docs-serve:
	$(MKDOCS) serve

docs-build:
	$(MKDOCS) build --strict

landing-install:
	cd $(LANDING) && $(NPM) ci

landing-dev:
	cd $(LANDING) && $(NPM) run dev

landing-build:
	cd $(LANDING) && $(NPM) run build

# The published artifact: the landing at / and the documentation under /docs/.
site: landing-build docs-build
	rm -rf $(SITE)
	mkdir -p $(SITE)
	cp -R $(LANDING)/dist/. $(SITE)/
	cp -R site $(SITE)/docs

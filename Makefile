NPM := npm
LANDING := landing
DOCS := docs
SITE := _site

.PHONY: docs-install docs-dev docs-build landing-install landing-dev landing-build site

docs-install:
	cd $(DOCS) && $(NPM) ci

docs-dev:
	cd $(DOCS) && $(NPM) run dev

docs-build:
	cd $(DOCS) && $(NPM) run build

landing-install:
	cd $(LANDING) && $(NPM) ci

landing-dev:
	cd $(LANDING) && $(NPM) run dev

landing-build:
	cd $(LANDING) && $(NPM) run build

# The published artifact: the landing at / and the Starlight documentation under /docs/.
site: landing-build docs-build
	rm -rf $(SITE)
	mkdir -p $(SITE)
	cp -R $(LANDING)/dist/. $(SITE)/
	cp -R $(DOCS)/dist/. $(SITE)/docs/

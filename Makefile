SHELL := /bin/bash
.DEFAULT_GOAL := app

export APP_VERSION
export BUILD_VERSION
export SDKROOT

.PHONY: app test validate validate-dmg check release \
	install-helper uninstall-helper help

app:
	@./scripts/build-app.sh

test:
	@./scripts/swift-test.sh
	@./scripts/test-local-helper-common.sh
	@/bin/bash ./scripts/test-helper-package-common.sh
	@/bin/bash ./scripts/test-signature-flag-parsing.sh

validate:
	@./scripts/validate-app.sh "$(CURDIR)/dist/Caffeine.app"

validate-dmg:
	@version="$${APP_VERSION:-1.0.0}"; \
	build="$${BUILD_VERSION:-4}"; \
	EXPECTED_APP_VERSION="$$version" \
	EXPECTED_BUILD_VERSION="$$build" \
	REQUIRE_NOTARIZATION=0 \
		./scripts/validate-dmg.sh \
		"$(CURDIR)/dist/Caffeine-$$version-build-$$build-macOS-universal.dmg"

check: test app

release: test
	@./scripts/release.sh

install-helper:
	@sudo /bin/bash ./scripts/install-local-helper.sh

uninstall-helper:
	@sudo /bin/bash ./scripts/uninstall-local-helper.sh

help:
	@printf '%s\n' \
		'make app       Build a Universal 2, ad-hoc-signed development app.' \
		'make test      Run the Swift test suite with a compatible macOS SDK.' \
		'make validate  Validate the assembled app, helper, plists, and signatures.' \
		'make validate-dmg  Validate the downloadable community disk image.' \
		'make check     Run tests and the app build’s mandatory validation.' \
		'make release   Build, validate, and checksum the GitHub Release DMG.' \
		'make install-helper    Install/update the optional root helper.' \
		'make uninstall-helper  Safely remove the optional root helper.'

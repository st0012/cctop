PROJECT = menubar/CctopMenubar.xcodeproj
DERIVED = menubar/build
SIGN = CODE_SIGN_IDENTITY="-"

.PHONY: all build test swift-test snapshots lint contract clean install run restart

all: lint contract build test

build:
	xcodebuild build -project $(PROJECT) -scheme CctopMenubar -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)
	xcodebuild build -project $(PROJECT) -scheme cctop-hook -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)
	mkdir -p $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources
	cp plugins/opencode/plugin.js $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/opencode-plugin.js
	cp plugins/pi/cctop.ts $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/pi-plugin.ts
	cp plugins/codex/cctop-shim.sh $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/codex-shim.sh
	cp plugins/codex/hooks.json $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/codex-hooks.json
	rm -rf $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/com.st0012.cctop.sdPlugin
	cp -R plugins/streamdeck/com.st0012.cctop.sdPlugin $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/

test:
	npm --prefix plugins/opencode test
	npm --prefix plugins/streamdeck test
	scripts/test-bump-streamdeck-version.sh
	if node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 23 || (major === 23 && minor >= 6) ? 0 : 1)'; then \
		node --test plugins/pi/test/*.test.mjs; \
	else \
		echo "WARNING: skipping pi extension tests: Node >= 23.6 required for TypeScript type stripping, found $$(node --version)"; \
	fi
	$(MAKE) swift-test

swift-test:
	scripts/run-swift-tests-isolated.sh \
		test -project $(PROJECT) -scheme CctopMenubar -configuration Debug \
		-derivedDataPath $(DERIVED) $(SIGN) \
		-skip-testing:CctopMenubarTests/SnapshotTests \
		-skip-testing:CctopMenubarTests/QASnapshotTests

# Artifact generators are opt-in and run behind the same isolated test boundary.
snapshots:
	scripts/run-swift-tests-isolated.sh \
		test -project $(PROJECT) -scheme CctopMenubar -configuration Debug \
		-derivedDataPath $(DERIVED) $(SIGN) \
		-only-testing:CctopMenubarTests/SnapshotTests \
		-only-testing:CctopMenubarTests/QASnapshotTests \
		-only-testing:CctopMenubarTests/WorktreeCleanupScenarioSnapshotTests

lint:
	swiftlint lint --strict

contract:
	scripts/validate-fixtures.sh
	scripts/validate-hooks-coverage.sh
	scripts/test-validate-release-version.sh

clean:
	xcodebuild clean -project $(PROJECT) -scheme CctopMenubar -derivedDataPath $(DERIVED)
	rm -rf $(DERIVED)

install:
	xcodebuild build -project $(PROJECT) -scheme cctop-hook -configuration Release -derivedDataPath $(DERIVED) $(SIGN)
	mkdir -p ~/.cctop/bin
	rm -f ~/.cctop/bin/cctop-hook
	cp $(DERIVED)/Build/Products/Release/cctop-hook ~/.cctop/bin/cctop-hook

run: build
	open $(DERIVED)/Build/Products/Debug/CctopMenubar.app

restart: build
	$(MAKE) install
	-pkill -x CctopMenubar
	sleep 0.5
	open $(DERIVED)/Build/Products/Debug/CctopMenubar.app

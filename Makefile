PROJECT = menubar/CctopMenubar.xcodeproj
DERIVED = menubar/build
SIGN = CODE_SIGN_IDENTITY="-"

.PHONY: all build test lint contract clean install run restart

all: lint contract build test

build:
	xcodebuild build -project $(PROJECT) -scheme CctopMenubar -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)
	xcodebuild build -project $(PROJECT) -scheme cctop-hook -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)
	mkdir -p $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources
	cp plugins/opencode/plugin.js $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/opencode-plugin.js
	cp plugins/pi/cctop.ts $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/pi-plugin.ts
	cp plugins/codex/cctop-shim.sh $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/codex-shim.sh
	cp plugins/codex/hooks.json $(DERIVED)/Build/Products/Debug/CctopMenubar.app/Contents/Resources/codex-hooks.json

test:
	npm --prefix plugins/opencode test
	xcodebuild test -project $(PROJECT) -scheme CctopMenubar -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)

lint:
	swiftlint lint --strict

contract:
	scripts/validate-fixtures.sh
	scripts/validate-hooks-coverage.sh

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

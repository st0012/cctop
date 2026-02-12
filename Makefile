PROJECT = menubar/CctopMenubar.xcodeproj
DERIVED = menubar/build
SIGN = CODE_SIGN_IDENTITY="-"

.PHONY: all build test lint clean install run

all: lint build test

build:
	xcodebuild build -project $(PROJECT) -scheme CctopMenubar -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)
	xcodebuild build -project $(PROJECT) -scheme cctop-hook -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)

test:
	xcodebuild test -project $(PROJECT) -scheme CctopMenubar -configuration Debug -derivedDataPath $(DERIVED) $(SIGN)

lint:
	swiftlint lint --strict

clean:
	xcodebuild clean -project $(PROJECT) -scheme CctopMenubar -derivedDataPath $(DERIVED)
	rm -rf $(DERIVED)

install:
	xcodebuild build -project $(PROJECT) -scheme cctop-hook -configuration Release -derivedDataPath $(DERIVED) $(SIGN)
	mkdir -p ~/.cctop/bin
	cp $(DERIVED)/Build/Products/Release/cctop-hook ~/.cctop/bin/cctop-hook

run: build
	open $(DERIVED)/Build/Products/Debug/CctopMenubar.app

VERSION ?= 1.3.1
export VERSION

.PHONY: build debug run test install clean icon snapshots screenshots dist dmg release

build:
	scripts/bundle.sh release

debug:
	scripts/bundle.sh debug

run: build
	open build/SecureTunnels.app

test:
	swift test

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

install: build
	@pkill -x SecureTunnels || true
	rm -rf /Applications/SecureTunnels.app
	cp -R build/SecureTunnels.app /Applications/SecureTunnels.app
	open /Applications/SecureTunnels.app

snapshots: debug
	build/SecureTunnels.app/Contents/MacOS/SecureTunnels --snapshot build/snapshots
	@ls build/snapshots

screenshots: debug
	build/SecureTunnels.app/Contents/MacOS/SecureTunnels --snapshot docs/screenshots --demo
	build/SecureTunnels.app/Contents/MacOS/SecureTunnels --snapshot docs/screenshots/dark --demo --dark
	@ls docs/screenshots docs/screenshots/dark

dist: build dmg
	rm -f build/SecureTunnels-$(VERSION).zip
	ditto -c -k --keepParent build/SecureTunnels.app build/SecureTunnels-$(VERSION).zip
	@ls -la build/SecureTunnels-$(VERSION).zip build/SecureTunnels-$(VERSION).dmg

dmg: build
	scripts/make-dmg.sh

release:
	scripts/release.sh

clean:
	rm -rf .build build

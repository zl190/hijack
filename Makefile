# Hijack maintainer tasks. Run `make <target>`. See docs/distribution-spec.md for the full spec.
.PHONY: build test lint fmt install release release-checks release-assets release-publish cask diagrams clean

# SIGN_ID: the codesign identity. Empty means ad-hoc; build.sh signs ad-hoc when the identity is empty.
# build and install use SIGN_ID as given (empty by default, so a dev build stays ad-hoc).
# release uses RELEASE_SIGN_ID: SIGN_ID if set, else "Hijack Signing".
SIGN_ID ?=
RELEASE_SIGN_ID = $(if $(strip $(SIGN_ID)),$(SIGN_ID),Hijack Signing)

VERSION := $(shell cat VERSION)
APP     := build/Hijack.app
ZIP     := build/Hijack.zip
# Sparkle tools; build.sh extracts them with the framework, one folder per version.
SPARKLE_VERSION := $(shell sed -n 's/^SPARKLE_VERSION=//p' build.sh)
SPARKLE_BIN ?= .sparkle/$(SPARKLE_VERSION)/bin
RELEASE_URL := https://github.com/zl190/hijack/releases/download/v$(VERSION)/
# TAP_DIR: path to the zl190/homebrew-tap checkout. Override for a different layout.
TAP_DIR ?= ../homebrew-tap

# Build build/Hijack.app. Ad-hoc unless SIGN_ID names a keychain identity.
build:
	HIJACK_SIGN_ID="$(SIGN_ID)" ./build.sh

# Run the HijackCore unit tests.
test:
	swift test

# Check formatting against .swift-format without changing files; see docs/swift-format.md.
lint:
	xcrun swift-format lint --strict --recursive Sources Tests

# Rewrite files in place to match .swift-format; see docs/swift-format.md.
fmt:
	xcrun swift-format format --in-place --recursive Sources Tests

# Build, then install to /Applications and link the hijack command.
install: build
	pkill -x Hijack 2>/dev/null || true
	rm -rf /Applications/Hijack.app
	cp -R $(APP) /Applications/
	for try in 1 2 3; do open /Applications/Hijack.app && break; sleep 2; done
	if [ -d "$$HOME/.local/bin" ] && echo ":$$PATH:" | grep -q ":$$HOME/.local/bin:"; then \
		ln -sf /Applications/Hijack.app/Contents/MacOS/Hijack "$$HOME/.local/bin/hijack"; \
		echo "Linked the hijack command into ~/.local/bin"; \
	else \
		echo "For the hijack command: ln -s /Applications/Hijack.app/Contents/MacOS/Hijack <a directory on your PATH>/hijack"; \
	fi
	echo "Hijack installed. Allow it in System Settings > Privacy & Security > Accessibility."

# Publish the GitHub release and bump the Homebrew cask. Run on the maintainer's Mac only.
# Every step checks its own done-state first, so a run that stopped midway completes on the next run:
# assets already uploaded: no rebuild, no upload (a rebuild would change the bytes behind the published sha);
# release already public: no edit; cask already at this version and sha: no bump.
# Order: tests, checks (tag, release exists, identity, Sparkle key), assets, publish, cask.
release: test release-checks release-assets release-publish cask

release-checks:
	@dirty="$$(git status --porcelain)"; [ -z "$$dirty" ] || { \
		echo "The tree has uncommitted changes:"; echo "$$dirty"; \
		echo "Commit or stash them before you release: the zip must match the tag (review-4 M3)."; exit 1; \
	}
	@git describe --tags --exact-match HEAD 2>/dev/null | grep -qx "v$(VERSION)" || { \
		echo "HEAD is not tagged v$(VERSION). Check out the tag before you release."; exit 1; \
	}
	@gh release view "v$(VERSION)" --json tagName >/dev/null 2>&1 || { \
		echo "No release v$(VERSION) on GitHub. Push the tag: the release workflow creates the draft."; exit 1; \
	}
	@security find-certificate -c "$(RELEASE_SIGN_ID)" >/dev/null 2>&1 || { \
		echo "Signing identity '$(RELEASE_SIGN_ID)' is not in the keychain."; exit 1; \
	}
	@grep -q '^REPLACE-' assets/sparkle-public-key.txt && { \
		echo "assets/sparkle-public-key.txt is the placeholder. Run generate_keys and paste the public key."; exit 1; \
	} || true

# Build, zip, write and sign the appcast, upload both assets. Skipped when the release already has both.
# Sparkle: one archive per version in dist/ (older zips stay there, out of git). The appcast keeps one item,
# the new release: older items would get this release's download URL, where their zips do not exist.
# generate_appcast reads the .md next to the zip as release notes (embedded as Markdown; a link would point
# at a file that is never uploaded), signs the archive with the EdDSA key from the keychain, and writes
# dist/appcast.xml. The release asset keeps the name Hijack.zip (the cask URL), so the enclosure URL is
# rewritten from Hijack-$(VERSION).zip to Hijack.zip.
release-assets:
	@assets="$$(gh release view "v$(VERSION)" --json assets -q '.assets[].name')"; \
	if echo "$$assets" | grep -qx "Hijack.zip" && echo "$$assets" | grep -qx "appcast.xml"; then \
		echo "v$(VERSION) already has Hijack.zip and appcast.xml: no build, no upload"; exit 0; \
	fi; \
	set -e; \
	HIJACK_SIGN_ID="$(RELEASE_SIGN_ID)" ./build.sh; \
	ditto -c -k --keepParent $(APP) $(ZIP); \
	mkdir -p dist; \
	cp $(ZIP) dist/Hijack-$(VERSION).zip; \
	cp release-notes/v$(VERSION).md dist/Hijack-$(VERSION).md; \
	$(SPARKLE_BIN)/generate_appcast --embed-release-notes --maximum-versions 1 --download-url-prefix "$(RELEASE_URL)" dist; \
	grep 'Hijack-$(VERSION)\.zip"' dist/appcast.xml | grep -q 'sparkle:edSignature=' || { \
		echo "The $(VERSION) item in dist/appcast.xml has no EdDSA signature. Is the Sparkle key in the keychain, and does it match the public key in the app?"; exit 1; \
	}; \
	sed -i '' 's|/Hijack-$(VERSION)\.zip"|/Hijack.zip"|' dist/appcast.xml; \
	gh release upload "v$(VERSION)" $(ZIP) dist/appcast.xml --clobber

release-publish:
	@if gh release view "v$(VERSION)" --json isDraft -q '.isDraft' | grep -q true; then \
		gh release edit "v$(VERSION)" --draft=false; \
	else echo "v$(VERSION) is already public"; fi

# Bump the cask to the published asset. The sha comes from the asset on GitHub, never from a local zip:
# a rebuild gives different bytes. Safe to run alone after a failed release, and safe to run twice.
cask:
	@set -e; \
	mkdir -p dist/published && rm -f dist/published/Hijack.zip; \
	gh release download "v$(VERSION)" -p Hijack.zip -D dist/published; \
	sha="$$(shasum -a 256 dist/published/Hijack.zip | awk '{print $$1}')"; \
	if grep -q "version \"$(VERSION)\"" "$(TAP_DIR)/Casks/hijack.rb" && grep -q "sha256 \"$$sha\"" "$(TAP_DIR)/Casks/hijack.rb"; then \
		echo "cask already at $(VERSION) with the published sha"; exit 0; \
	fi; \
	sed -i '' -e "s/version \"[^\"]*\"/version \"$(VERSION)\"/" \
		-e "s/sha256 \"[^\"]*\"/sha256 \"$$sha\"/" "$(TAP_DIR)/Casks/hijack.rb"; \
	if command -v brew >/dev/null 2>&1; then brew audit --cask --strict --online zl190/tap/hijack; fi; \
	cd "$(TAP_DIR)" && git add Casks/hijack.rb && \
	(git diff --cached --quiet || git commit -m "hijack $(VERSION)") && git push

# Regenerate the diagrams in docs/diagrams from the code and the tests.
diagrams:
	scripts/diagrams.sh

# Remove build output.
clean:
	rm -rf build dist
